// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
/// @title TheClique ETH Bank (Best)
/// @notice Secure, scalable, decentralized bank for community: register, deposit, withdraw, and manage collateralized loans.
/// @dev Optimized for Monad Testnet with governance and upgradeability readiness.

contract Bank is ReentrancyGuard, AccessControl {
    // --- Roles ---
    bytes32 public constant LOAN_APPROVER_ROLE = keccak256("LOAN_APPROVER_ROLE");

    // --- State ---
    address public immutable owner;
    uint256 public totalFeesCollected;
    uint256 public totalCollateralLocked;

    // --- Fees and Config ---
    uint256 public constant CREATE_USER_PRICE = 0.5 ether;
    uint256 public constant LOAN_REQUEST_FEE = 0.01 ether;
    uint256 public constant WITHDRAWAL_FEE_PERCENT = 2;
    uint256 public constant LOAN_INTEREST_RATE = 5;
    uint256 public constant LOAN_COLLATERAL_RATIO = 150;
    uint256 public constant MAX_LOAN_AMOUNT = 100 ether;
    uint256 public constant MAX_NAME_LENGTH = 32;
    uint256 public constant MAX_PURPOSE_LENGTH = 100;
    uint256 public constant FEE_WITHDRAWAL_TIMELOCK = 1 days;
    uint256 public constant MAX_LOANS_PER_USER = 5;
    uint256 public constant GRACE_PERIOD = 7 days;
    uint256 public constant LIQUIDATOR_REWARD = 5;

    // --- Timelock for Fee Withdrawals ---
    struct WithdrawalRequest {
        uint256 amount;
        uint256 unlockTimestamp;
        bool executed;
    }

    mapping(address => WithdrawalRequest) public withdrawalRequests;

    // --- User Data ---
    struct UserInfo {
        uint8 age;
        string name;
        bool isMarried;
        address account;
    }

    mapping(address => UserInfo) public userInfo;
    mapping(address => bool) public hasAccount;
    mapping(address => uint256) public userBalances;
    mapping(address => uint256) public userCollateral;
    mapping(address => SendStatus) public senderStatus;

    // --- Loan Data ---
    struct Loan {
        uint256 amount;
        string purpose;
        bool isApproved;
        bool isRejected;
        uint256 timestamp;
        address approvedBy;
        bool isRepaid;
        uint256 interest;
        uint256 dueTimestamp;
        uint256 collateral;
    }

    mapping(address => Loan[]) public loans;

    // --- Enums ---
    enum SendStatus {
        HASDEPOSITED,
        AWAITINGDEPOSIT
    }

    // --- Events ---
    event UserRegistered(address indexed user, string name, uint8 age);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amountAfterFee, uint256 fee);
    event LoanRequested(address indexed user, uint256 amount, string purpose, uint256 index);
    event LoanApproved(address indexed user, uint256 amount, uint256 index);
    event LoanRejected(address indexed user, uint256 index, string reason);
    event LoanRepaid(address indexed user, uint256 amount, uint256 index);
    event LoanLiquidated(address indexed user, uint256 index, uint256 collateral, uint256 reward);
    event FeeWithdrawalRequested(address indexed admin, uint256 amount, uint256 unlockTimestamp);
    event FeeWithdrawalExecuted(address indexed admin, uint256 amount);

    // --- Errors ---
    error AlreadyRegistered();
    error InsufficientRegistrationFee();
    error MustSendETH();
    error InsufficientBalance();
    error MaxLoansReached();
    error InvalidLoanIndex();
    error LoanAlreadyApproved();
    error LoanAlreadyRejected();
    error BankLowOnFunds();
    error InvalidLoanState();
    error InsufficientRepayment();
    error InsufficientFees();
    error ETHTransferFailed();
    error InvalidAge();
    error NameTooLong();
    error PurposeTooLong();
    error ExcessiveLoanAmount();
    error InsufficientCollateral();
    error TimelockNotExpired();
    error WithdrawalAlreadyExecuted();

    // --- Modifiers ---
    modifier onlyRegistered() {
        if (!hasAccount[msg.sender]) revert("User not registered");
        _;
    }

    // --- Constructor ---
    constructor() {
        owner = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LOAN_APPROVER_ROLE, msg.sender);
    }

    // --- User Registration ---
    function setUserInfo(uint8 userAge, string memory userName, bool isUserMarried) public payable nonReentrant {
        if (hasAccount[msg.sender]) revert AlreadyRegistered();
        if (msg.value < CREATE_USER_PRICE) revert InsufficientRegistrationFee();
        if (userAge == 0 || userAge > 150) revert InvalidAge();
        if (bytes(userName).length > MAX_NAME_LENGTH) revert NameTooLong();

        if (msg.value > CREATE_USER_PRICE) {
            _safeTransferETH(msg.sender, msg.value - CREATE_USER_PRICE);
        }

        userInfo[msg.sender] = UserInfo(userAge, userName, isUserMarried, msg.sender);
        hasAccount[msg.sender] = true;
        totalFeesCollected += CREATE_USER_PRICE;

        emit UserRegistered(msg.sender, userName, userAge);
    }

    // --- Deposit ---
    function makeDeposit() public payable onlyRegistered nonReentrant {
        if (msg.value == 0) revert MustSendETH();

        userBalances[msg.sender] += msg.value;
        senderStatus[msg.sender] = SendStatus.HASDEPOSITED;

        emit Deposited(msg.sender, msg.value);
    }

    // --- Withdrawals ---
    function withdrawMyBalance(uint256 amount) public onlyRegistered nonReentrant {
        if (userBalances[msg.sender] < amount) revert InsufficientBalance();
        uint256 fee = (amount * WITHDRAWAL_FEE_PERCENT) / 100;
        uint256 amountAfterFee = amount - fee;
        userBalances[msg.sender] -= amount;
        totalFeesCollected += fee;
        _safeTransferETH(msg.sender, amountAfterFee);
        emit Withdrawn(msg.sender, amountAfterFee, fee);
    }

    // --- Loan System ---
    function requestLoan(uint256 amountRequested, string memory purpose) public payable onlyRegistered nonReentrant {
        if (msg.value < LOAN_REQUEST_FEE) revert InsufficientRegistrationFee();
        if (loans[msg.sender].length >= MAX_LOANS_PER_USER) revert MaxLoansReached();
        if (amountRequested > MAX_LOAN_AMOUNT) revert ExcessiveLoanAmount();
        if (bytes(purpose).length > MAX_PURPOSE_LENGTH) revert PurposeTooLong();

        uint256 requiredCollateral = (amountRequested * LOAN_COLLATERAL_RATIO) / 100;
        if (userBalances[msg.sender] < requiredCollateral) revert InsufficientCollateral();

        if (msg.value > LOAN_REQUEST_FEE) {
            _safeTransferETH(msg.sender, msg.value - LOAN_REQUEST_FEE);
        }

        userBalances[msg.sender] -= requiredCollateral;
        userCollateral[msg.sender] += requiredCollateral;
        totalCollateralLocked += requiredCollateral;

        uint256 interest = (amountRequested * LOAN_INTEREST_RATE) / 100;
        loans[msg.sender].push(
            Loan({
                amount: amountRequested,
                purpose: purpose,
                isApproved: false,
                isRejected: false,
                timestamp: block.timestamp,
                approvedBy: address(0),
                isRepaid: false,
                interest: interest,
                dueTimestamp: block.timestamp + 30 days,
                collateral: requiredCollateral
            })
        );

        totalFeesCollected += LOAN_REQUEST_FEE;
        emit LoanRequested(msg.sender, amountRequested, purpose, loans[msg.sender].length - 1);
    }

    function getLoanHealth(address user, uint256 index) public view returns (uint256 healthFactor) {
        if (index >= loans[user].length) return 0;
        Loan memory loan = loans[user][index];
        if (!loan.isApproved || loan.isRepaid) return 0;
        uint256 collateralValue = loan.collateral;
        uint256 debt = loan.amount + loan.interest;
        return (collateralValue * 100) / debt;
    }

    function approveLoan(address user, uint256 index) public onlyRole(LOAN_APPROVER_ROLE) nonReentrant {
        if (index >= loans[user].length) revert InvalidLoanIndex();
        Loan storage loan = loans[user][index];
        if (loan.isApproved) revert LoanAlreadyApproved();
        if (loan.isRejected) revert LoanAlreadyRejected();

        loan.isApproved = true;
        loan.approvedBy = msg.sender;

        userBalances[user] += loan.amount;
        emit LoanApproved(user, loan.amount, index);
    }

    function rejectLoan(address user, uint256 index, string memory reason)
        public
        onlyRole(LOAN_APPROVER_ROLE)
        nonReentrant
    {
        if (index >= loans[user].length) revert InvalidLoanIndex();
        Loan storage loan = loans[user][index];
        if (loan.isApproved) revert LoanAlreadyApproved();
        if (loan.isRejected) revert LoanAlreadyRejected();

        userBalances[user] += loan.collateral;
        userCollateral[user] -= loan.collateral;
        totalCollateralLocked -= loan.collateral;

        loan.isRejected = true;
        loan.approvedBy = msg.sender;

        emit LoanRejected(user, index, reason);
    }

    function repayLoan(uint256 index) public payable onlyRegistered nonReentrant {
        if (index >= loans[msg.sender].length) revert InvalidLoanIndex();
        Loan storage loan = loans[msg.sender][index];
        if (!loan.isApproved || loan.isRepaid || loan.isRejected) revert InvalidLoanState();
        if (msg.value < loan.amount + loan.interest) revert InsufficientRepayment();

        if (msg.value > loan.amount + loan.interest) {
            _safeTransferETH(msg.sender, msg.value - (loan.amount + loan.interest));
        }

        userBalances[msg.sender] += loan.collateral;
        userCollateral[msg.sender] -= loan.collateral;
        totalCollateralLocked -= loan.collateral;

        loan.isRepaid = true;
        userBalances[msg.sender] -= loan.amount;
        totalFeesCollected += loan.interest;

        emit LoanRepaid(msg.sender, loan.amount + loan.interest, index);
    }

    function liquidateLoan(address user, uint256 index) public onlyRole(LOAN_APPROVER_ROLE) nonReentrant {
        if (index >= loans[user].length) revert InvalidLoanIndex();
        Loan storage loan = loans[user][index];
        if (!loan.isApproved || loan.isRepaid || loan.isRejected) revert InvalidLoanState();
        if (block.timestamp <= loan.dueTimestamp + GRACE_PERIOD) revert("Loan not overdue");

        uint256 reward = (loan.collateral * LIQUIDATOR_REWARD) / 100;
        uint256 bankShare = loan.collateral - reward;

        userCollateral[user] -= loan.collateral;
        totalCollateralLocked -= loan.collateral;
        totalFeesCollected += bankShare;
        loan.isRepaid = true;
        userBalances[user] -= loan.amount;

        _safeTransferETH(msg.sender, reward);

        emit LoanLiquidated(user, index, loan.collateral, reward);
    }

    // --- Admin Functions ---
    function requestFeeWithdrawal(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount > totalFeesCollected) revert InsufficientFees();
        if (address(this).balance < amount) revert BankLowOnFunds();

        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount: amount,
            unlockTimestamp: block.timestamp + FEE_WITHDRAWAL_TIMELOCK,
            executed: false
        });

        emit FeeWithdrawalRequested(msg.sender, amount, block.timestamp + FEE_WITHDRAWAL_TIMELOCK);
    }

    function executeFeeWithdrawal() public onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        if (request.amount == 0 || request.executed) revert WithdrawalAlreadyExecuted();
        if (block.timestamp < request.unlockTimestamp) revert TimelockNotExpired();

        uint256 amount = request.amount;
        request.executed = true;
        totalFeesCollected -= amount;

        _safeTransferETH(msg.sender, amount);

        emit FeeWithdrawalExecuted(msg.sender, amount);
    }

    // --- View Functions ---
    function getBankBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getUserInfo(address user) public view returns (uint8, string memory, bool, uint256, uint256) {
        UserInfo memory info = userInfo[user];
        return (info.age, info.name, info.isMarried, userBalances[user], userCollateral[user]);
    }

    function getLoan(address user, uint256 index)
        public
        view
        returns (
            uint256 amount,
            string memory purpose,
            bool isApproved,
            bool isRejected,
            uint256 timestamp,
            address approvedBy,
            bool isRepaid,
            uint256 interest,
            uint256 dueTimestamp,
            uint256 collateral
        )
    {
        if (index >= loans[user].length) revert InvalidLoanIndex();
        Loan memory loan = loans[user][index];
        return (
            loan.amount,
            loan.purpose,
            loan.isApproved,
            loan.isRejected,
            loan.timestamp,
            loan.approvedBy,
            loan.isRepaid,
            loan.interest,
            loan.dueTimestamp,
            loan.collateral
        );
    }

    function getUserLoanCount(address user) public view returns (uint256) {
        return loans[user].length;
    }

    // --- Internal Helpers ---
    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    // --- Fallbacks ---
    receive() external payable {
        revert("Use makeDeposit()");
    }

    fallback() external payable {
        revert("Use makeDeposit()");
    }
}
