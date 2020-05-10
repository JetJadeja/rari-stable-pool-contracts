pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "./lib/RariFundController.sol";
import "./RariFundToken.sol";

/**
 * @title RariFundManager
 * @dev This contract is the primary contract powering RariFund.
 * Anyone can deposit to the fund with deposit(string currencyCode, uint256 amount)
 * Anyone can withdraw their funds (with interest) from the fund with withdraw(string currencyCode, uint256 amount)
 */
contract RariFundManager is Ownable {
    using SafeMath for uint256;

    /**
     * @dev Boolean that, if true, disables deposits to and withdrawals from this RariFundManager.
     */
    bool private _fundDisabled;

    /**
     * @dev Address of the RariFundToken.
     */
    address private _rariFundTokenContract;

    /**
     * @dev Maps ERC20 token contract addresses to their currency codes.
     */
    mapping(string => address) private _erc20Contracts;

    /**
     * @dev Maps arrays of supported pools to currency codes.
     */
    mapping(string => uint8[]) private _poolsByCurrency;

    /**
     * @dev Struct for a pending withdrawal.
     */
    struct PendingWithdrawal {
        address payee;
        uint256 amount;
    }

    /**
     * @dev Mapping of withdrawal queues to currency codes.
     */
    mapping(string => PendingWithdrawal[]) private _withdrawalQueues;

    /**
     * @dev Constructor that sets supported ERC20 token contract addresses and supported pools for each supported token.
     */
    constructor () public {
        _erc20Contracts["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        _poolsByCurrency["DAI"].push(0);
        _poolsByCurrency["DAI"].push(1);
    }

    /**
     * @dev Fallback function to receive ETH to be used for gas fees.
     */
    function() external payable { }

    /**
     * @dev Emitted when RariFundManager is upgraded.
     */
    event FundManagerUpgraded(address newContract);

    /**
     * @dev Emitted when the RariFundToken of the RariFundManager is set.
     */
    event FundTokenSet(address newContract);

    /**
     * @dev Upgrades RariFundManager.
     * @param newContract The address of the new RariFundManager contract.
     */
    function upgradeFundManager(address newContract) external onlyOwner {
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");

        // Update RariFundToken minter
        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        rariFundToken.addMinter(newContract);
        rariFundToken.renounceMinter();

        // Withdraw all from all pools
        for (uint256 i = 0; i < _poolsByCurrency["DAI"].length; i++)
            if (RariFundController.getPoolBalance(_poolsByCurrency["DAI"][i], _erc20Contracts["DAI"]) > 0)
                RariFundController.withdrawAllFromPool(_poolsByCurrency["DAI"][i], _erc20Contracts["DAI"]);

        // Transfer all tokens
        ERC20 token = ERC20(_erc20Contracts["DAI"]);
        token.transfer(newContract, token.balanceOf(address(this)));

        emit FundManagerUpgraded(newContract);
    }

    /**
     * @dev Sets or upgrades the RariFundToken of the RariFundManager.
     * @param newContract The address of the new RariFundToken contract.
     */
    function setFundToken(address newContract) external onlyOwner {
        _rariFundTokenContract = newContract;
        emit FundTokenSet(newContract);
    }

    /**
     * @dev Emitted when deposits to and withdrawals from this RariFundManager have been disabled.
     */
    event FundDisabled();

    /**
     * @dev Emitted when deposits to and withdrawals from this RariFundManager have been enabled.
     */
    event FundEnabled();

    /**
     * @dev Disables deposits to and withdrawals from this RariFundManager while contract(s) are upgraded.
     */
    function disableFund() external onlyOwner {
        require(!_fundDisabled, "Fund already disabled.");
        _fundDisabled = true;
        emit FundDisabled();
    }

    /**
     * @dev Enables deposits to and withdrawals from this RariFundManager once contract(s) are upgraded.
     */
    function enableFund() external onlyOwner {
        require(_fundDisabled, "Fund already enabled.");
        _fundDisabled = false;
        emit FundEnabled();
    }

    /**
     * @dev Calculates an account's total balance of the specified currency.
     */
    function balanceOf(string calldata currencyCode, address account) external returns (uint256) {
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        if (rftTotalSupply == 0) return 0;
        uint256 rftBalance = rariFundToken.balanceOf(account);
        uint256 totalBalance = this.getTotalBalance(currencyCode);
        uint256 tokenBalance = rftBalance.mul(totalBalance).div(rftTotalSupply);

        return tokenBalance;
    }

    /**
     * @dev Calculates the fund's total balance of the specified currency.
     */
    function getTotalBalance(string memory currencyCode) public returns (uint256) {
        require(_poolsByCurrency[currencyCode].length > 0, "Invalid currency code.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        ERC20 token = ERC20(erc20Contract);
        uint256 totalBalance = token.balanceOf(address(this));
        for (uint256 i = 0; i < _poolsByCurrency[currencyCode].length; i++) totalBalance = totalBalance.add(RariFundController.getPoolBalance(_poolsByCurrency[currencyCode][i], erc20Contract));
        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) totalBalance = totalBalance.sub(_withdrawalQueues[currencyCode][i].amount);

        return totalBalance;
    }

    /**
     * @dev Emitted when funds have been deposited to RariFund.
     */
    event Deposit(string indexed currencyCode, address indexed sender, uint256 amount);

    /**
     * @dev Emitted when funds have been withdrawn from RariFund.
     */
    event Withdrawal(string indexed currencyCode, address indexed payee, uint256 amount);

    /**
     * @dev Emitted when funds have been queued for withdrawal from RariFund.
     */
    event WithdrawalQueued(string indexed currencyCode, address indexed payee, uint256 amount);

    /**
     * @dev Deposits funds to RariFund in exchange for RFT.
     * @param currencyCode The current code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     */
    function deposit(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        ERC20Detailed token = ERC20Detailed(erc20Contract);
        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 rftAmount = 0;

        if (rftTotalSupply > 0) {
            rftAmount = amount.mul(rftTotalSupply).div(this.getTotalBalance(currencyCode));
        } else {
            uint256 rftDecimals = rariFundToken.decimals();
            uint256 tokenDecimals = token.decimals();
            rftAmount = rftDecimals >= tokenDecimals ? amount.mul(10 ** (rftDecimals - tokenDecimals)) : amount.div(10 ** (tokenDecimals - rftDecimals));
        }

        // The user must approve the transfer of tokens before calling this function
        require(token.transferFrom(msg.sender, address(this), amount), "Failed to transfer input tokens.");

        require(rariFundToken.mint(msg.sender, rftAmount), "Failed to mint output tokens.");

        emit Deposit(currencyCode, msg.sender, amount);
        return true;
    }

    /**
     * @dev Withdraws funds from RariFund in exchange for RFT.
     * @param currencyCode The current code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     */
    function withdraw(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        ERC20 token = ERC20(erc20Contract);
        uint256 contractBalance = token.balanceOf(address(this));

        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 totalBalance = this.getTotalBalance(currencyCode);
        uint256 rftAmount = amount.mul(rftTotalSupply).div(totalBalance);
        require(rftAmount <= rariFundToken.balanceOf(msg.sender), "Your RFT balance is too low for a withdrawal of this amount.");
        require(amount <= totalBalance, "Fund DAI balance is too low for a withdrawal of this amount.");

        // TODO: The user must approve the burning of tokens before calling this function
        rariFundToken.burnFrom(msg.sender, rftAmount);

        if (amount <= contractBalance) {
            require(token.transfer(msg.sender, amount), "Failed to transfer output tokens.");
            emit Withdrawal(currencyCode, msg.sender, amount);
        } else  {
            _withdrawalQueues[currencyCode].push(PendingWithdrawal(msg.sender, amount));
            emit WithdrawalQueued(currencyCode, msg.sender, amount);
        }

        return true;
    }

    /**
     * @dev Processes pending withdrawals in the queue for the specified currency.
     * @param currencyCode The currency code of the token for which to process pending withdrawals.
     */
    function processPendingWithdrawals(string calldata currencyCode) external onlyOwner returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        ERC20 token = ERC20(erc20Contract);
        uint256 balanceHere = token.balanceOf(address(this));
        uint256 total = 0;
        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) total = total.add(_withdrawalQueues[currencyCode][i].amount);
        if (total > balanceHere) revert("Not enough balance to process pending withdrawals.");

        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) {
            require(token.transfer(_withdrawalQueues[currencyCode][i].payee, _withdrawalQueues[currencyCode][i].amount));
            emit Withdrawal(currencyCode, _withdrawalQueues[currencyCode][i].payee, _withdrawalQueues[currencyCode][i].amount);
        }

        _withdrawalQueues[currencyCode].length = 0;
        return true;
    }

    /**
     * @dev Counts the number of pending withdrawals in the queue for the specified currency.
     */
    function countPendingWithdrawals(string calldata currencyCode) external view returns (uint256) {
        return _withdrawalQueues[currencyCode].length;
    }

    /**
     * @dev Returns the payee of a pending withdrawal for the specified currency.
     */
    function getPendingWithdrawalPayee(string calldata currencyCode, uint256 index) external view returns (address) {
        return _withdrawalQueues[currencyCode][index].payee;
    }

    /**
     * @dev Returns the amount of a pending withdrawal for the specified currency.
     */
    function getPendingWithdrawalAmount(string calldata currencyCode, uint256 index) external view returns (uint256) {
        return _withdrawalQueues[currencyCode][index].amount;
    }

    /**
     * @dev Deposits funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     */
    function depositToPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyOwner returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.depositToPool(pool, erc20Contract, amount), "Pool deposit failed.");
        return true;
    }

    /**
     * @dev Withdraws funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     */
    function withdrawFromPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyOwner returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.withdrawFromPool(pool, erc20Contract, amount), "Pool withdrawal failed.");
        return true;
    }

    /**
     * @dev Withdraws all funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The ERC20 contract of the token to be withdrawn.
     */
    function withdrawAllFromPool(uint8 pool, string calldata currencyCode) external onlyOwner returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.withdrawAllFromPool(pool, erc20Contract), "Pool withdrawal failed.");
        return true;
    }
}
