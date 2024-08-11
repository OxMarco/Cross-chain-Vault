// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Vault is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public totalAssetsBalance;
    mapping(address => uint256) public pendingDepositRequest;
    mapping(address => uint256) public pendingWithdrawalRequest;
    IERC20 public immutable vaultAsset;

    event DepositRequest(uint256 assets, address indexed receiver, address indexed owner);
    event CancelDeposit(uint256 assets, address indexed receiver);
    event WithdrawRequest(uint256 assets, address indexed receiver);
    event CancelWithdrawal(uint256 assets, address indexed receiver);

    constructor(IERC20 _asset, string memory _name, string memory _symbol) ERC20(_name, _symbol) ERC4626(_asset) {
        vaultAsset = _asset;
    }

    function totalAssets() public view override returns (uint256) {
        return totalAssetsBalance;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(totalAssetsBalance, _convertToAssets(balanceOf(owner), Math.Rounding.Floor));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(convertToShares(totalAssetsBalance), balanceOf(owner));
    }

    function requestDeposit(uint256 assets, address receiver) external returns (uint256) {
        vaultAsset.safeTransferFrom(msg.sender, address(this), assets);
        pendingDepositRequest[receiver] += assets;
        emit DepositRequest(assets, receiver, msg.sender);
        return assets;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        pendingDepositRequest[receiver] -= assets;
        totalAssetsBalance += assets;

        shares = convertToShares(assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    function cancelDeposit() external {
        uint256 assets = pendingDepositRequest[msg.sender];
        pendingDepositRequest[msg.sender] = 0;
        vaultAsset.safeTransfer(msg.sender, assets);

        emit CancelDeposit(assets, msg.sender);
    }

    function requestWithdrawal(uint256 assets) external returns (uint256) {
        pendingWithdrawalRequest[msg.sender] += assets;
        emit WithdrawRequest(assets, msg.sender);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        pendingWithdrawalRequest[receiver] -= assets;
        totalAssetsBalance -= assets;

        uint256 shares = convertToShares(assets);
        _burn(owner, shares);
        vaultAsset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return shares;
    }

    function cancelWithdrawal() external {
        uint256 assets = pendingWithdrawalRequest[msg.sender];
        pendingWithdrawalRequest[msg.sender] = 0;

        emit CancelWithdrawal(assets, msg.sender);
    }
}
