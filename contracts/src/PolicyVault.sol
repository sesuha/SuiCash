// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PolicyVault
/// @notice Holds the owner's funds and enforces every hard limit on-chain, so that a fooled model,
///         a bypassed policy engine or a stolen session key still cannot drain the wallet.
/// @dev Layer 3 of SuiCash's three defence layers. The agent (a session key or an ERC-4337 smart
///      account) may only pay allowlisted, activated recipients, within per-transaction,
///      per-recipient and daily caps, without breaching the safety buffer, once per intent ID,
///      while the session is valid and the vault is not paused. Everything else is the owner's.
///      No delegatecall, no upgradeability, no selfdestruct, no arbitrary external calls, and the
///      agent cannot grant token approvals.
contract PolicyVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Delay before a cap increase (or a savings pool change) can take effect.
    uint64 public constant LIMIT_TIMELOCK = 24 hours;
    /// @notice Longest session the owner can grant in one call.
    uint64 public constant MAX_SESSION_DURATION = 30 days;
    /// @notice Delay before a newly added recipient can be paid by the agent, unless changed.
    uint64 public constant DEFAULT_RECIPIENT_DELAY = 1 hours;
    /// @notice Upper bound for the recipient delay.
    uint64 public constant MAX_RECIPIENT_DELAY = 30 days;
    /// @notice How long a T2 request stays approvable.
    uint64 public constant REQUEST_TTL = 72 hours;
    /// @notice Most payments in one executeBatch call.
    uint256 public constant MAX_BATCH_SIZE = 10;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct TokenConfig {
        bool enabled;
        uint128 perTxCap;
        uint128 dailyCap;
    }

    struct DailySpend {
        uint64 day; // block.timestamp / 1 days
        uint128 amount; // spent by the agent on that day
    }

    struct RecipientConfig {
        bool allowed;
        uint128 perPaymentCap;
        uint64 activeFrom;
    }

    struct PendingIncrease {
        uint128 perTxCap;
        uint128 dailyCap;
        uint64 eta;
    }

    struct PendingPoolChange {
        address pool;
        uint64 eta;
    }

    enum RequestStatus {
        None,
        Pending,
        Approved,
        Rejected,
        Expired
    }

    struct Request {
        address token;
        address to;
        uint256 amount;
        bytes32 intentId;
        uint64 expiresAt;
        RequestStatus status;
    }

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    /// @notice Optional address that may only pause, revoke the session and cancel timelocked changes.
    address public guardian;
    /// @notice The single active session (zero address means none).
    address public agent;
    /// @notice Last second (inclusive) at which the agent may act.
    uint64 public agentValidUntil;
    /// @notice Seconds between adding a recipient and the agent being able to pay it.
    uint64 public recipientDelay;
    /// @notice The only contract the agent may move funds to or from besides recipients.
    address public savingsPool;
    /// @notice A queued savings pool change.
    PendingPoolChange public pendingSavingsPool;
    /// @notice Number of T2 requests created; request IDs run from 1 to requestCount.
    uint256 public requestCount;

    /// @notice Per-token switch and caps, in token units.
    mapping(address token => TokenConfig) public tokens;
    /// @notice Per-token amount the agent spent today.
    mapping(address token => DailySpend) public spent;
    /// @notice The on-chain allowlist of payees.
    mapping(address recipient => RecipientConfig) public recipients;
    /// @notice The agent may never take the vault's balance of a token below this.
    mapping(address token => uint256) public minBuffer;
    /// @notice Queued cap increases.
    mapping(address token => PendingIncrease) public pendingIncrease;
    /// @notice Replay protection: each intent ID executes at most once.
    mapping(bytes32 intentId => bool) public usedIntent;

    mapping(uint256 id => Request) private _requests;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event AgentSet(address indexed agent, uint64 validUntil);
    event AgentRevoked(address indexed agent, address indexed by);
    event TransferExecuted(
        bytes32 indexed intentId, address indexed token, address indexed to, uint256 amount, uint256 spentToday
    );
    event BatchExecuted(bytes32 indexed intentId, address indexed token, uint256 count, uint256 total);
    event TransferRequested(
        uint256 indexed id,
        bytes32 indexed intentId,
        address indexed token,
        address to,
        uint256 amount,
        bytes32 memoHash,
        uint64 expiresAt
    );
    event RequestApproved(uint256 indexed id, address indexed token, address indexed to, uint256 amount);
    event RequestRejected(uint256 indexed id);
    event RecipientAdded(address indexed recipient, uint128 perPaymentCap, uint64 activeFrom);
    event RecipientRemoved(address indexed recipient);
    event RecipientDelaySet(uint64 delay);
    event TokenEnabled(address indexed token, uint128 perTxCap, uint128 dailyCap);
    event LimitsDecreased(address indexed token, uint128 perTxCap, uint128 dailyCap);
    event LimitIncreaseQueued(address indexed token, uint128 perTxCap, uint128 dailyCap, uint64 eta);
    event LimitIncreaseExecuted(address indexed token, uint128 perTxCap, uint128 dailyCap);
    event LimitIncreaseCancelled(address indexed token);
    event MinBufferSet(address indexed token, uint256 amount);
    event GuardianSet(address indexed guardian);
    event SavingsPoolChangeQueued(address indexed pool, uint64 eta);
    event SavingsPoolChanged(address indexed pool);
    event SavingsPoolChangeCancelled(address indexed pool);
    event SavingsDeposit(address indexed asset, uint256 assets, uint256 shares);
    event SavingsWithdraw(address indexed asset, uint256 assets, uint256 shares);
    event OwnerWithdraw(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors (with arguments, so reverts read clearly on a block explorer)
    // ---------------------------------------------------------------------

    error WalletPaused();
    error NotAgent(address caller);
    error SessionExpired(uint64 validUntil);
    error NotOwnerOrGuardian(address caller);
    error InvalidAmount();
    error InvalidAddress(address account);
    error InvalidRecipient(address to);
    error InvalidIntent();
    error InvalidCaps(uint128 perTxCap, uint128 dailyCap);
    error InvalidSessionExpiry(uint64 validUntil);
    error InvalidDelay(uint64 delay);
    error TokenNotAllowed(address token);
    error RecipientNotAllowed(address to);
    error RecipientNotActiveYet(address to, uint64 activeFrom);
    error RecipientAlreadyAdded(address to);
    error IntentAlreadyUsed(bytes32 intentId);
    error ExceedsPerTxLimit(uint256 amount, uint256 cap);
    error ExceedsRecipientLimit(address to, uint256 amount, uint256 cap);
    error ExceedsDailyLimit(uint256 amount, uint256 remaining);
    error BelowSafetyBuffer(uint256 balance, uint256 amount, uint256 minBuffer);
    error EmptyBatch();
    error BatchTooLarge(uint256 count);
    error LengthMismatch(uint256 recipients, uint256 amounts);
    error NoPendingIncrease(address token);
    error NoPendingPoolChange();
    error TimelockNotElapsed(uint64 eta);
    error SavingsPoolNotSet();
    error RequestNotPending(uint256 id);
    error RequestExpired(uint256 id);
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && (msg.sender != guardian || guardian == address(0))) {
            revert NotOwnerOrGuardian(msg.sender);
        }
        _;
    }

    /// @dev Handbook 2.4 step 2.
    modifier onlyActiveAgent() {
        if (msg.sender != agent || agent == address(0)) revert NotAgent(msg.sender);
        if (block.timestamp > agentValidUntil) revert SessionExpired(agentValidUntil);
        _;
    }

    /// @param owner_ The account that owns the funds (an EOA or a smart account).
    /// @param savingsPool_ The ERC-4626 pool for idle funds; may be zero and set later.
    constructor(address owner_, address savingsPool_) Ownable(owner_) {
        recipientDelay = DEFAULT_RECIPIENT_DELAY;
        if (savingsPool_ != address(0)) {
            savingsPool = savingsPool_;
            emit SavingsPoolChanged(savingsPool_);
        }
    }

    // =====================================================================
    // Agent: T1 path
    // =====================================================================

    /// @notice Pays an allowlisted recipient within every limit. Checks run in handbook 2.4 order.
    /// @param token The enabled token to pay with.
    /// @param to The recipient; must be allowlisted and past its activation time.
    /// @param amount Amount in token units.
    /// @param intentId Unique ID issued by the policy engine; executes at most once.
    function executeTransfer(address token, address to, uint256 amount, bytes32 intentId)
        external
        whenNotPaused
        nonReentrant
        onlyActiveAgent
    {
        // 3. Basic argument checks.
        if (amount == 0) revert InvalidAmount();
        _checkRecipientAddress(to);
        // 4. Token enabled.
        TokenConfig memory cfg = _enabledToken(token);
        // 5. Recipient allowlisted and active.
        uint128 recipientCap = _activeRecipientCap(to);
        // 6. Replay protection.
        _useIntent(intentId);
        // 7. Per-transaction and per-recipient caps.
        _checkPaymentCaps(cfg, to, recipientCap, amount);
        // 8. Daily cap (rolls over at the start of each UTC day).
        uint256 spentBefore = _spentToday(token);
        _checkDailyCap(cfg, spentBefore, amount);
        uint256 spentAfter = spentBefore + amount;
        // 9. Safety buffer.
        uint256 balance = IERC20(token).balanceOf(address(this));
        _checkBuffer(token, balance, amount);
        // 10. Effects, then the interaction.
        _setSpentToday(token, spentAfter);
        IERC20(token).safeTransfer(to, amount);
        emit TransferExecuted(intentId, token, to, amount, spentAfter);
    }

    /// @notice Pays 1 to 10 allowlisted recipients in one call (payroll, contractor payouts, grants).
    ///         Each item runs every executeTransfer check, counts toward the daily cap in order, and
    ///         uses its own intent ID `itemIntentId(intentId, index)`. Any failing item reverts the
    ///         whole call.
    /// @param token The enabled token to pay with.
    /// @param to Recipients, one per item.
    /// @param amounts Amounts in token units, one per item.
    /// @param intentId Batch intent ID issued by the policy engine; executes at most once.
    function executeBatch(address token, address[] calldata to, uint256[] calldata amounts, bytes32 intentId)
        external
        whenNotPaused
        nonReentrant
        onlyActiveAgent
    {
        uint256 count = to.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_BATCH_SIZE) revert BatchTooLarge(count);
        if (amounts.length != count) revert LengthMismatch(count, amounts.length);

        TokenConfig memory cfg = _enabledToken(token);
        _useIntent(intentId);

        uint256 spentBefore = _spentToday(token);
        uint256 spentAfter = spentBefore;
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Checks and effects for every item first, in order, so each item sees the earlier ones.
        for (uint256 i = 0; i < count; ++i) {
            address recipient = to[i];
            uint256 amount = amounts[i];
            if (amount == 0) revert InvalidAmount();
            _checkRecipientAddress(recipient);
            uint128 recipientCap = _activeRecipientCap(recipient);
            _useIntent(itemIntentId(intentId, i));
            _checkPaymentCaps(cfg, recipient, recipientCap, amount);
            _checkDailyCap(cfg, spentAfter, amount);
            spentAfter += amount;
            _checkBuffer(token, balance, amount);
            balance -= amount;
        }
        _setSpentToday(token, spentAfter);

        // Then the interactions.
        _payBatch(token, to, amounts, intentId, spentBefore);
        emit BatchExecuted(intentId, token, count, spentAfter - spentBefore);
    }

    // =====================================================================
    // Agent: T2 path
    // =====================================================================

    /// @notice Records a payment that needs the owner's approval. Moves no funds.
    /// @param token The enabled token to pay with.
    /// @param to The proposed recipient (need not be allowlisted).
    /// @param amount Amount in token units (may exceed the caps).
    /// @param intentId Unique ID issued by the policy engine.
    /// @param memoHash Hash of the memo; the memo text itself stays off-chain.
    /// @return id The new request's ID.
    function requestTransfer(address token, address to, uint256 amount, bytes32 intentId, bytes32 memoHash)
        external
        whenNotPaused
        nonReentrant
        onlyActiveAgent
        returns (uint256 id)
    {
        if (amount == 0) revert InvalidAmount();
        _checkRecipientAddress(to);
        _enabledToken(token);
        _useIntent(intentId);

        id = ++requestCount;
        // forge-lint: disable-next-line(unsafe-typecast) - uint64 seconds last ~584 billion years
        uint64 expiresAt = uint64(block.timestamp) + REQUEST_TTL;
        _requests[id] = Request({
            token: token,
            to: to,
            amount: amount,
            intentId: intentId,
            expiresAt: expiresAt,
            status: RequestStatus.Pending
        });
        emit TransferRequested(id, intentId, token, to, amount, memoHash, expiresAt);
    }

    // =====================================================================
    // Agent: savings
    // =====================================================================

    /// @notice Moves idle funds from the vault into the savings pool. The vault keeps the shares.
    /// @param amount Amount of the pool's asset to deposit.
    function depositToSavings(uint256 amount) external whenNotPaused nonReentrant onlyActiveAgent {
        (address pool, address asset) = _savings(amount);
        _checkBuffer(asset, IERC20(asset).balanceOf(address(this)), amount);

        IERC20(asset).forceApprove(pool, amount);
        uint256 shares = IERC4626(pool).deposit(amount, address(this));
        // The pool pulls exactly `amount`; clear any remainder so no allowance outlives the call.
        IERC20(asset).forceApprove(pool, 0);
        emit SavingsDeposit(asset, amount, shares);
    }

    /// @notice Moves funds from the savings pool back into the vault. Funds always return here.
    /// @param amount Amount of the pool's asset to withdraw.
    function withdrawFromSavings(uint256 amount) external whenNotPaused nonReentrant onlyActiveAgent {
        (address pool, address asset) = _savings(amount);
        uint256 shares = IERC4626(pool).withdraw(amount, address(this), address(this));
        emit SavingsWithdraw(asset, amount, shares);
    }

    // =====================================================================
    // Owner: approvals
    // =====================================================================

    /// @notice Pays a pending request. Works for non-allowlisted recipients and above the caps,
    ///         because the owner decided; still blocked while paused.
    /// @param id The request ID.
    function approveRequest(uint256 id) external onlyOwner whenNotPaused nonReentrant {
        Request storage request = _requests[id];
        if (request.status != RequestStatus.Pending) revert RequestNotPending(id);
        if (block.timestamp > request.expiresAt) revert RequestExpired(id);
        request.status = RequestStatus.Approved;
        IERC20(request.token).safeTransfer(request.to, request.amount);
        emit RequestApproved(id, request.token, request.to, request.amount);
    }

    /// @notice Rejects a pending (or expired) request.
    /// @param id The request ID.
    function rejectRequest(uint256 id) external onlyOwner {
        Request storage request = _requests[id];
        if (request.status != RequestStatus.Pending) revert RequestNotPending(id);
        request.status = RequestStatus.Rejected;
        emit RequestRejected(id);
    }

    // =====================================================================
    // Owner: session
    // =====================================================================

    /// @notice Grants a session, replacing any existing one.
    /// @param newAgent The session key address or the agent smart account.
    /// @param validUntil Last valid second; at most MAX_SESSION_DURATION from now.
    function setAgent(address newAgent, uint64 validUntil) external onlyOwner {
        if (newAgent == address(0) || newAgent == address(this) || newAgent == owner()) {
            revert InvalidAddress(newAgent);
        }
        if (validUntil <= block.timestamp || validUntil > block.timestamp + MAX_SESSION_DURATION) {
            revert InvalidSessionExpiry(validUntil);
        }
        agent = newAgent;
        agentValidUntil = validUntil;
        emit AgentSet(newAgent, validUntil);
    }

    /// @notice Ends the session immediately.
    function revokeAgent() external onlyOwnerOrGuardian {
        address previous = agent;
        agent = address(0);
        agentValidUntil = 0;
        emit AgentRevoked(previous, msg.sender);
    }

    // =====================================================================
    // Owner: limits
    // =====================================================================

    /// @notice Sets a token's caps. The first call enables the token immediately. After that,
    ///         decreases apply now and increases are queued for LIMIT_TIMELOCK. A new call replaces
    ///         any queued increase. Setting both caps to zero disables agent spending.
    /// @param token The token.
    /// @param perTxCap Largest single agent payment, in token units.
    /// @param dailyCap Most the agent may spend per UTC day, in token units.
    function setTokenLimits(address token, uint128 perTxCap, uint128 dailyCap) external onlyOwner {
        if (token == address(0)) revert InvalidAddress(token);
        if (perTxCap > dailyCap) revert InvalidCaps(perTxCap, dailyCap);
        TokenConfig storage cfg = tokens[token];

        if (!cfg.enabled) {
            cfg.enabled = true;
            cfg.perTxCap = perTxCap;
            cfg.dailyCap = dailyCap;
            emit TokenEnabled(token, perTxCap, dailyCap);
            return;
        }

        uint128 lowerPerTx = perTxCap < cfg.perTxCap ? perTxCap : cfg.perTxCap;
        uint128 lowerDaily = dailyCap < cfg.dailyCap ? dailyCap : cfg.dailyCap;
        if (lowerPerTx != cfg.perTxCap || lowerDaily != cfg.dailyCap) {
            cfg.perTxCap = lowerPerTx;
            cfg.dailyCap = lowerDaily;
            emit LimitsDecreased(token, lowerPerTx, lowerDaily);
        }

        if (perTxCap > cfg.perTxCap || dailyCap > cfg.dailyCap) {
            // forge-lint: disable-next-line(unsafe-typecast) - uint64 seconds last ~584 billion years
            uint64 eta = uint64(block.timestamp) + LIMIT_TIMELOCK;
            pendingIncrease[token] = PendingIncrease({perTxCap: perTxCap, dailyCap: dailyCap, eta: eta});
            emit LimitIncreaseQueued(token, perTxCap, dailyCap, eta);
        } else if (pendingIncrease[token].eta != 0) {
            delete pendingIncrease[token];
            emit LimitIncreaseCancelled(token);
        }
    }

    /// @notice Applies a queued cap increase once its timelock has passed. Anyone may call it.
    /// @param token The token.
    function executeLimitIncrease(address token) external {
        PendingIncrease memory pending = pendingIncrease[token];
        // eta == 0 is the "nothing queued" sentinel, not a timing comparison.
        // slither-disable-next-line incorrect-equality
        if (pending.eta == 0) revert NoPendingIncrease(token);
        if (block.timestamp < pending.eta) revert TimelockNotElapsed(pending.eta);
        delete pendingIncrease[token];
        tokens[token].perTxCap = pending.perTxCap;
        tokens[token].dailyCap = pending.dailyCap;
        emit LimitIncreaseExecuted(token, pending.perTxCap, pending.dailyCap);
    }

    /// @notice Cancels a queued cap increase.
    /// @param token The token.
    function cancelLimitIncrease(address token) external onlyOwnerOrGuardian {
        if (pendingIncrease[token].eta == 0) revert NoPendingIncrease(token);
        delete pendingIncrease[token];
        emit LimitIncreaseCancelled(token);
    }

    /// @notice Sets the balance the agent may never take the vault below.
    /// @param token The token.
    /// @param amount The buffer, in token units.
    function setMinBuffer(address token, uint256 amount) external onlyOwner {
        minBuffer[token] = amount;
        emit MinBufferSet(token, amount);
    }

    // =====================================================================
    // Owner: recipients
    // =====================================================================

    /// @notice Allowlists a recipient. The agent can pay it from now + recipientDelay.
    ///         To change a recipient's cap, remove and add it again (the delay restarts).
    /// @param recipient The payee.
    /// @param perPaymentCap Largest single agent payment to this payee, in token units.
    function addRecipient(address recipient, uint128 perPaymentCap) external onlyOwner {
        _checkRecipientAddress(recipient);
        if (perPaymentCap == 0) revert InvalidAmount();
        if (recipients[recipient].allowed) revert RecipientAlreadyAdded(recipient);
        // forge-lint: disable-next-line(unsafe-typecast) - uint64 seconds last ~584 billion years
        uint64 activeFrom = uint64(block.timestamp) + recipientDelay;
        recipients[recipient] = RecipientConfig({allowed: true, perPaymentCap: perPaymentCap, activeFrom: activeFrom});
        emit RecipientAdded(recipient, perPaymentCap, activeFrom);
    }

    /// @notice Removes a recipient from the allowlist immediately.
    /// @param recipient The payee.
    function removeRecipient(address recipient) external onlyOwner {
        if (!recipients[recipient].allowed) revert RecipientNotAllowed(recipient);
        delete recipients[recipient];
        emit RecipientRemoved(recipient);
    }

    /// @notice Sets the activation delay for recipients added from now on (0 allowed for demos).
    /// @param delay Seconds, at most MAX_RECIPIENT_DELAY.
    function setRecipientDelay(uint64 delay) external onlyOwner {
        if (delay > MAX_RECIPIENT_DELAY) revert InvalidDelay(delay);
        recipientDelay = delay;
        emit RecipientDelaySet(delay);
    }

    // =====================================================================
    // Owner: guardian, savings pool, pause, escape hatch
    // =====================================================================

    /// @notice Sets the guardian (zero address for none).
    /// @param newGuardian The guardian address.
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(this) || (newGuardian != address(0) && newGuardian == agent)) {
            revert InvalidAddress(newGuardian);
        }
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Sets the savings pool. Immediate if none is set; otherwise queued for LIMIT_TIMELOCK.
    /// @param pool An ERC-4626 vault whose asset is an enabled token.
    function setSavingsPool(address pool) external onlyOwner {
        if (pool == address(0) || pool == address(this)) revert InvalidAddress(pool);
        if (savingsPool == address(0)) {
            savingsPool = pool;
            emit SavingsPoolChanged(pool);
            return;
        }
        // forge-lint: disable-next-line(unsafe-typecast) - uint64 seconds last ~584 billion years
        uint64 eta = uint64(block.timestamp) + LIMIT_TIMELOCK;
        pendingSavingsPool = PendingPoolChange({pool: pool, eta: eta});
        emit SavingsPoolChangeQueued(pool, eta);
    }

    /// @notice Applies a queued savings pool change once its timelock has passed. Anyone may call it.
    function executeSavingsPoolChange() external {
        PendingPoolChange memory pending = pendingSavingsPool;
        // eta == 0 is the "nothing queued" sentinel, not a timing comparison.
        // slither-disable-next-line incorrect-equality
        if (pending.eta == 0) revert NoPendingPoolChange();
        if (block.timestamp < pending.eta) revert TimelockNotElapsed(pending.eta);
        delete pendingSavingsPool;
        savingsPool = pending.pool;
        emit SavingsPoolChanged(pending.pool);
    }

    /// @notice Cancels a queued savings pool change.
    function cancelSavingsPoolChange() external onlyOwnerOrGuardian {
        address pool = pendingSavingsPool.pool;
        if (pendingSavingsPool.eta == 0) revert NoPendingPoolChange();
        delete pendingSavingsPool;
        emit SavingsPoolChangeCancelled(pool);
    }

    /// @notice Stops every agent function and approvals.
    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    /// @notice Resumes. Only the owner can unpause; the guardian cannot.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice The owner's escape hatch: moves any token anywhere, with no caps. Works while paused.
    /// @param token The token.
    /// @param to The receiver.
    /// @param amount Amount in token units.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress(to);
        if (amount == 0) revert InvalidAmount();
        IERC20(token).safeTransfer(to, amount);
        emit OwnerWithdraw(token, to, amount);
    }

    /// @notice Disabled: renouncing ownership would lock the funds forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // =====================================================================
    // Views
    // =====================================================================

    /// @notice The intent ID of item `index` in a batch, used for replay protection.
    /// @param batchIntentId The batch's intent ID.
    /// @param index Zero-based item index.
    function itemIntentId(bytes32 batchIntentId, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(batchIntentId, index));
    }

    /// @notice What the agent has spent of `token` today.
    /// @param token The token.
    function spentToday(address token) external view returns (uint256) {
        return _spentToday(token);
    }

    /// @notice What the agent may still spend of `token` today, ignoring the balance and buffer.
    /// @param token The token.
    function remainingDailyCap(address token) external view returns (uint256) {
        uint256 cap = tokens[token].dailyCap;
        uint256 used = _spentToday(token);
        return used >= cap ? 0 : cap - used;
    }

    /// @notice Whether the agent can currently pay `recipient` (allowlisted and activated).
    /// @param recipient The payee.
    function isRecipientActive(address recipient) external view returns (bool) {
        RecipientConfig memory r = recipients[recipient];
        return r.allowed && block.timestamp >= r.activeFrom;
    }

    /// @notice Whether a session is active right now.
    function isSessionActive() external view returns (bool) {
        return agent != address(0) && block.timestamp <= agentValidUntil && !paused();
    }

    /// @notice A T2 request. A pending request past its expiry is reported as Expired.
    /// @param id The request ID.
    function getRequest(uint256 id) external view returns (Request memory request) {
        request = _requests[id];
        // An enum comparison; the timestamp is only compared with `>`.
        // slither-disable-next-line incorrect-equality
        if (request.status == RequestStatus.Pending && block.timestamp > request.expiresAt) {
            request.status = RequestStatus.Expired;
        }
    }

    // =====================================================================
    // Internals
    // =====================================================================

    /// @dev Reverts with WalletPaused (a named error for the evidence log) instead of EnforcedPause.
    function _requireNotPaused() internal view override {
        if (paused()) revert WalletPaused();
    }

    function _checkRecipientAddress(address to) private view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
    }

    function _enabledToken(address token) private view returns (TokenConfig memory cfg) {
        cfg = tokens[token];
        if (!cfg.enabled) revert TokenNotAllowed(token);
    }

    function _activeRecipientCap(address to) private view returns (uint128) {
        RecipientConfig memory r = recipients[to];
        if (!r.allowed) revert RecipientNotAllowed(to);
        if (block.timestamp < r.activeFrom) revert RecipientNotActiveYet(to, r.activeFrom);
        return r.perPaymentCap;
    }

    function _useIntent(bytes32 intentId) private {
        if (intentId == bytes32(0)) revert InvalidIntent();
        if (usedIntent[intentId]) revert IntentAlreadyUsed(intentId);
        usedIntent[intentId] = true;
    }

    function _checkPaymentCaps(TokenConfig memory cfg, address to, uint128 recipientCap, uint256 amount) private pure {
        if (amount > cfg.perTxCap) revert ExceedsPerTxLimit(amount, cfg.perTxCap);
        if (amount > recipientCap) revert ExceedsRecipientLimit(to, amount, recipientCap);
    }

    /// @dev Safe when the cap was lowered below what was already spent today: remaining is then 0.
    function _checkDailyCap(TokenConfig memory cfg, uint256 spentBefore, uint256 amount) private pure {
        uint256 remaining = spentBefore >= cfg.dailyCap ? 0 : cfg.dailyCap - spentBefore;
        if (amount > remaining) revert ExceedsDailyLimit(amount, remaining);
    }

    function _checkBuffer(address token, uint256 balance, uint256 amount) private view {
        uint256 buffer = minBuffer[token];
        if (balance < amount || balance - amount < buffer) revert BelowSafetyBuffer(balance, amount, buffer);
    }

    /// @dev Transfers for an already fully checked batch; emits one TransferExecuted per item.
    function _payBatch(
        address token,
        address[] calldata to,
        uint256[] calldata amounts,
        bytes32 intentId,
        uint256 runningSpent
    ) private {
        for (uint256 i = 0; i < to.length; ++i) {
            runningSpent += amounts[i];
            IERC20(token).safeTransfer(to[i], amounts[i]);
            emit TransferExecuted(itemIntentId(intentId, i), token, to[i], amounts[i], runningSpent);
        }
    }

    function _today() private view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast) - uint64 seconds last ~584 billion years
        return uint64(block.timestamp / 1 days);
    }

    function _spentToday(address token) private view returns (uint256) {
        DailySpend memory s = spent[token];
        // Compares UTC-day buckets: "same day" is exactly equality, and a validator can only skew
        // block.timestamp by seconds, which cannot reopen a day's allowance early in any useful way.
        // slither-disable-next-line incorrect-equality
        return s.day == _today() ? s.amount : 0;
    }

    /// @dev `amount` never exceeds dailyCap (a uint128), so the cast cannot truncate.
    function _setSpentToday(address token, uint256 amount) private {
        // forge-lint: disable-next-line(unsafe-typecast) - amount <= dailyCap, a uint128 (see _checkDailyCap)
        spent[token] = DailySpend({day: _today(), amount: uint128(amount)});
    }

    function _savings(uint256 amount) private view returns (address pool, address asset) {
        pool = savingsPool;
        if (pool == address(0)) revert SavingsPoolNotSet();
        if (amount == 0) revert InvalidAmount();
        asset = IERC4626(pool).asset();
        _enabledToken(asset);
    }
}
