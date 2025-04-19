// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../lib/forge-std/src/Test.sol";
import "../src/CliqueBank.sol";

// Malicious contract to test reentrancy
contract ReentrancyAttacker {
    Bank bank;
    uint256 public attackCount;

    constructor(Bank _bank) {
        bank = _bank;
    }

    function attack() external payable {
        console.log("Starting attack, msg.value:", msg.value);
        console.log("Attack caller:", msg.sender);
        bank.withdrawMyBalance(msg.value);
    }

    receive() external payable {
        console.log("Receive called, attackCount:", attackCount);
        console.log("Receive caller:", msg.sender);
        if (attackCount < 1) {
            attackCount++;
            console.log("Attempting reentrancy, amount:", msg.value);
            bank.withdrawMyBalance(msg.value);
        }
    }
}

contract BankTest is Test {
    Bank bank;
    address owner = address(this);
    address user = address(0xBEEF);
    address approver = address(0xCAFE);
    address attacker = address(0xDEAD);
    ReentrancyAttacker reentrancyAttacker;

    // Constants from Bank.sol
    uint256 constant CREATE_USER_PRICE = 0.5 ether;
    uint256 constant LOAN_REQUEST_FEE = 0.01 ether;
    uint256 constant WITHDRAWAL_FEE_PERCENT = 2;
    uint256 constant LOAN_INTEREST_RATE = 5;
    uint256 constant LOAN_COLLATERAL_RATIO = 150;
    uint256 constant MAX_LOAN_AMOUNT = 100 ether;
    uint256 constant MAX_LOANS_PER_USER = 5;
    uint256 constant FEE_WITHDRAWAL_TIMELOCK = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant LIQUIDATOR_REWARD = 5;

    function setUp() public {
    bank = new Bank();
    vm.deal(address(bank), 10 ether); // Fund bank for loans
    vm.deal(user, 200 ether); // Increased to cover 151.5 ETH deposit + fees
    vm.deal(approver, 10 ether);
    vm.deal(attacker, 10 ether);
    bank.grantRole(bank.LOAN_APPROVER_ROLE(), approver);
    reentrancyAttacker = new ReentrancyAttacker(bank);
}

    // Allow test contract to receive ETH
    receive() external payable {}

    // --- Registration Tests ---
    function test_RegisterUser() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);

        (uint8 age, string memory name, bool isMarried, uint256 balance, uint256 collateral) = bank.getUserInfo(user);
        assertEq(age, 25);
        assertEq(name, "Alice");
        assertEq(isMarried, false);
        assertEq(balance, 0);
        assertEq(collateral, 0);
        assertTrue(bank.hasAccount(user));
        assertEq(bank.totalFeesCollected(), 0.5 ether);
    }

    function test_RevertWhen_RegisteringTwice() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.expectRevert(Bank.AlreadyRegistered.selector);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientRegistrationFee() public {
        vm.prank(user);
        vm.expectRevert(Bank.InsufficientRegistrationFee.selector);
        bank.setUserInfo{value: 0.1 ether}(25, "Alice", false);
    }

    function test_RevertWhen_InvalidAge() public {
        vm.prank(user);
        vm.expectRevert(Bank.InvalidAge.selector);
        bank.setUserInfo{value: 0.5 ether}(0, "Alice", false);
    }

    function test_RevertWhen_NameTooLong() public {
        vm.prank(user);
        vm.expectRevert(Bank.NameTooLong.selector);
        bank.setUserInfo{value: 0.5 ether}(25, string(abi.encodePacked("A", new bytes(33))), false);
    }

    function test_RegisterWithExcessETH() public {
        vm.prank(user);
        uint256 initialBalance = user.balance;
        bank.setUserInfo{value: 1 ether}(25, "Alice", false);
        assertEq(user.balance, initialBalance - 0.5 ether);
    }

    // --- Deposit Tests ---
    function test_Deposit() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        bank.makeDeposit{value: 1 ether}();
        assertEq(bank.userBalances(user), 1 ether);
        assertEq(uint256(bank.senderStatus(user)), uint256(Bank.SendStatus.HASDEPOSITED));
        assertEq(bank.getBankBalance(), 1.5 ether + 10 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositZeroETH() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.expectRevert(Bank.MustSendETH.selector);
        bank.makeDeposit{value: 0}();
        vm.stopPrank();
    }

    function test_RevertWhen_DepositUnregistered() public {
        vm.prank(user);
        vm.expectRevert("User not registered");
        bank.makeDeposit{value: 1 ether}();
    }

    // --- Withdrawal Tests ---
    function test_WithdrawWithFee() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        bank.makeDeposit{value: 1 ether}();
        uint256 initialBalance = user.balance;
        bank.withdrawMyBalance(1 ether);
        uint256 fee = (1 ether * WITHDRAWAL_FEE_PERCENT) / 100;
        assertEq(bank.userBalances(user), 0);
        assertEq(bank.totalFeesCollected(), 0.5 ether + fee);
        assertEq(user.balance, initialBalance + 1 ether - fee);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawInsufficientBalance() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.expectRevert(Bank.InsufficientBalance.selector);
        bank.withdrawMyBalance(1 ether);
        vm.stopPrank();
    }

    // --- Loan Tests ---
    function test_RequestLoan() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        bank.makeDeposit{value: 1.5 ether}();
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        assertEq(bank.getUserLoanCount(user), 1);
        (uint256 amount, string memory purpose, bool isApproved, bool isRejected, uint256 timestamp, address approvedBy, bool isRepaid, uint256 interest, uint256 dueTimestamp, uint256 collateral) = bank.getLoan(user, 0);
        assertEq(amount, 1 ether);
        assertEq(purpose, "Car");
        assertFalse(isApproved);
        assertFalse(isRejected);
        assertEq(timestamp, block.timestamp);
        assertEq(approvedBy, address(0));
        assertFalse(isRepaid);
        assertEq(interest, (1 ether * LOAN_INTEREST_RATE) / 100);
        assertEq(dueTimestamp, block.timestamp + 30 days);
        assertEq(collateral, 1.5 ether);
        assertEq(bank.userBalances(user), 0);
        assertEq(bank.userCollateral(user), 1.5 ether);
        assertEq(bank.totalCollateralLocked(), 1.5 ether);
        assertEq(bank.totalFeesCollected(), 0.5 ether + 0.01 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_LoanExcessiveAmount() public {
    vm.startPrank(user);
    bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
    bank.makeDeposit{value: 151.5 ether}(); // Enough for 101 ETH loan
    vm.expectRevert(Bank.ExcessiveLoanAmount.selector);
    bank.requestLoan{value: 0.01 ether}(101 ether, "Car");
    vm.stopPrank();
}

    function test_RevertWhen_LoanInsufficientCollateral() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        bank.makeDeposit{value: 1 ether}();
        vm.expectRevert(Bank.InsufficientCollateral.selector);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.stopPrank();
    }

    function test_RevertWhen_MaxLoansReached() public {
        vm.startPrank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        bank.makeDeposit{value: 7.5 ether}();
        for (uint256 i = 0; i < MAX_LOANS_PER_USER; i++) {
            bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        }
        vm.expectRevert(Bank.MaxLoansReached.selector);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.stopPrank();
    }

    function test_ApproveLoan() public {
    vm.prank(user);
    bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);

    vm.prank(user);
    bank.makeDeposit{value: 1.5 ether}();

    vm.prank(user);
    bank.requestLoan{value: 0.01 ether}(1 ether, "Car");

    console.log("Bank balance before approve:", address(bank).balance);

    vm.prank(approver);
    bank.approveLoan(user, 0);

    // Correct destructuring — skip all but the booleans we care about
    (,, bool isApproved, , , , bool isRepaid, , ,) = bank.getLoan(user, 0);

    assertTrue(isApproved, "Loan should be approved");
    assertFalse(isRepaid, "Loan should not be marked repaid");
    assertEq(bank.userBalances(user), 1 ether, "User should have loan amount");
    assertEq(bank.userCollateral(user), 1.5 ether, "Collateral should remain locked");
}

    function test_RevertWhen_ApproveNonApprover() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(attacker);
        vm.expectRevert();
        bank.approveLoan(user, 0);
    }

    function test_RejectLoan() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        uint256 initialBalance = user.balance;
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(approver);
        bank.rejectLoan(user, 0, "Bad credit");
        (,, bool isApproved, bool isRejected,,,,,,) = bank.getLoan(user, 0);
        assertFalse(isApproved);
        assertTrue(isRejected);
        assertEq(bank.userBalances(user), 1.5 ether);
        assertEq(user.balance, initialBalance - 0.01 ether);
    }

    function test_RepayLoan() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        uint256 initialBalance = user.balance;
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(approver);
        bank.approveLoan(user, 0);
        vm.prank(user);
        bank.repayLoan{value: 1.05 ether}(0);
        (,,,,,, bool isRepaid,,,) = bank.getLoan(user, 0);
        assertTrue(isRepaid);
        assertEq(bank.userBalances(user), 1.5 ether);
        assertEq(user.balance, initialBalance - 1.06 ether);
    }

    function test_RevertWhen_RepayInsufficientETH() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(approver);
        bank.approveLoan(user, 0);
        vm.prank(user);
        vm.expectRevert(Bank.InsufficientRepayment.selector);
        bank.repayLoan{value: 1 ether}(0);
    }

    function test_LiquidateLoan() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(approver);
        bank.approveLoan(user, 0);
        vm.warp(block.timestamp + 30 days + GRACE_PERIOD + 1);
        uint256 initialFees = bank.totalFeesCollected();
        uint256 initialApproverBalance = approver.balance;
        vm.prank(approver);
        bank.liquidateLoan(user, 0);
        (,,,,,, bool isRepaid,,,) = bank.getLoan(user, 0);
        assertTrue(isRepaid);
        assertEq(bank.userCollateral(user), 0);
        uint256 reward = (1.5 ether * LIQUIDATOR_REWARD) / 100;
        assertEq(bank.totalFeesCollected(), initialFees + 1.5 ether - reward);
        assertEq(approver.balance, initialApproverBalance + reward);
    }

    function test_RevertWhen_LiquidateWithinGracePeriod() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(approver);
        bank.approveLoan(user, 0);
        vm.warp(block.timestamp + 30 days + GRACE_PERIOD - 1);
        vm.prank(approver);
        vm.expectRevert("Loan not overdue");
        bank.liquidateLoan(user, 0);
    }

    // --- Loan Health Tests ---
    function test_GetLoanHealth() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: 1.5 ether}();
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(1 ether, "Car");
        vm.prank(approver);
        bank.approveLoan(user, 0);
        uint256 health = bank.getLoanHealth(user, 0);
        assertEq(health, 142); // 1.5 / (1 + 0.05) * 100 ≈ 142%
    }

    function test_GetLoanHealthInvalidLoan() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        uint256 health = bank.getLoanHealth(user, 999);
        assertEq(health, 0);
    }

    // --- Fee Withdrawal Tests ---
    function test_FeeWithdrawal() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(owner);
        bank.requestFeeWithdrawal(0.5 ether);
        vm.warp(block.timestamp + FEE_WITHDRAWAL_TIMELOCK + 1);
        uint256 initialBalance = owner.balance;
        vm.prank(owner);
        bank.executeFeeWithdrawal();
        assertEq(bank.totalFeesCollected(), 0);
        assertEq(owner.balance, initialBalance + 0.5 ether);
    }

    function test_RevertWhen_FeeWithdrawalTimelock() public {
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(owner);
        bank.requestFeeWithdrawal(0.5 ether);
        vm.prank(owner);
        vm.expectRevert(Bank.TimelockNotExpired.selector);
        bank.executeFeeWithdrawal();
    }

    // --- Security Tests ---
    function test_RevertWhen_ReentrancyAttack() public {
    bank = new Bank();
    vm.deal(address(bank), 100 ether);
    bank.grantRole(bank.LOAN_APPROVER_ROLE(), approver);
    reentrancyAttacker = new ReentrancyAttacker(bank);
    vm.deal(address(reentrancyAttacker), 20 ether);
    console.log("ReentrancyAttacker balance before setUserInfo:", address(reentrancyAttacker).balance);
    vm.prank(address(reentrancyAttacker));
    bank.setUserInfo{value: 0.5 ether}(25, "Mallory", false);
    console.log("Registered before deposit:", bank.hasAccount(address(reentrancyAttacker)));
    vm.prank(address(reentrancyAttacker));
    bank.makeDeposit{value: 3 ether}();
    console.log("Registered after deposit:", bank.hasAccount(address(reentrancyAttacker)));
    console.log("ReentrancyAttacker balance in bank:", bank.userBalances(address(reentrancyAttacker)));
    console.log("Bank balance before attack:", address(bank).balance);
    vm.prank(address(reentrancyAttacker));
    vm.expectRevert(Bank.ETHTransferFailed.selector);
    reentrancyAttacker.attack{value: 0.05 ether}();
}

    // --- Fuzz Tests ---
    function testFuzz_Deposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: amount}();
        assertEq(bank.userBalances(user), amount);
    }

    function testFuzz_LoanRequest(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MAX_LOAN_AMOUNT);
        uint256 collateral = (amount * LOAN_COLLATERAL_RATIO) / 100;
        vm.assume(collateral <= 100 ether);
        vm.prank(user);
        bank.setUserInfo{value: 0.5 ether}(25, "Alice", false);
        vm.prank(user);
        bank.makeDeposit{value: collateral}();
        vm.prank(user);
        bank.requestLoan{value: 0.01 ether}(amount, "Car");
        assertEq(bank.getUserLoanCount(user), 1);
        (uint256 loanAmount,,,,,,,,,) = bank.getLoan(user, 0);
        assertEq(loanAmount, amount);
    }
}