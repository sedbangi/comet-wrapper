// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {CometInterface, TotalsBasic} from "./vendor/CometInterface.sol";
import {CometMath} from "./vendor/CometMath.sol";


contract CometWrapper is ERC4626, CometMath {
    using SafeTransferLib for ERC20;

    uint64 internal constant FACTOR_SCALE = 1e18;
    uint64 internal constant BASE_INDEX_SCALE = 1e15;
    uint256 constant TRACKING_INDEX_SCALE = 1e15;

    struct UserBasic {
        uint104 principal;
        uint64 baseTrackingAccrued;
        uint64 baseTrackingIndex;
    }

    mapping(address => UserBasic) public userBasic;
    mapping(address => uint256) public rewardsClaimed;

    uint40 internal lastAccrualTime;
    uint256 public underlyingPrincipal;
    CometInterface immutable comet;

    constructor(
        ERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset, _name, _symbol) {
        comet = CometInterface(address(_asset));
        lastAccrualTime = getNowInternal();
    }
    
    function totalAssets() public view override returns (uint256) {
        uint64 baseSupplyIndex_ = accruedSupplyIndex(getNowInternal() - lastAccrualTime);
        uint256 principal = underlyingPrincipal;
        return principal > 0 ? presentValueSupply(baseSupplyIndex_, principal) : 0;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        updateBasePrincipal(receiver, signed256(assets));
        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        updateBasePrincipal(receiver, signed256(assets));
        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function updateBasePrincipal(
        address account,
        int256 changeToPrincipal
    ) internal {
        UserBasic memory basic = userBasic[account];
        uint104 principal = basic.principal;
        (uint64 baseSupplyIndex, uint64 trackingSupplyIndex) = getSupplyIndices();
        uint256 indexDelta = uint256(trackingSupplyIndex - basic.baseTrackingIndex);
        basic.baseTrackingAccrued += safe64(
            (uint104(principal) * indexDelta) / TRACKING_INDEX_SCALE
        );
        basic.baseTrackingIndex = trackingSupplyIndex;

        if (changeToPrincipal != 0) {
            uint256 balance = unsigned256(
                signed256(presentValueSupply(baseSupplyIndex, basic.principal)) + changeToPrincipal
            );
            basic.principal = principalValueSupply(baseSupplyIndex, balance);
            underlyingPrincipal += basic.principal;
        }

        userBasic[account] = basic;
    }


    function accruedSupplyIndex(uint timeElapsed) internal view returns (uint64) {
        (uint64 baseSupplyIndex_,) = getSupplyIndices();
        if (timeElapsed > 0) {
            uint utilization = comet.getUtilization();
            uint supplyRate = comet.getSupplyRate(utilization);
            baseSupplyIndex_ += safe64(mulFactor(baseSupplyIndex_, supplyRate * timeElapsed));
        }
        return baseSupplyIndex_;
    }

    function getSupplyIndices()
        internal
        view
        returns (uint64 baseSupplyIndex_, uint64 trackingSupplyIndex_)
    {
        TotalsBasic memory totals = comet.totalsBasic();
        baseSupplyIndex_ = totals.baseSupplyIndex;
        trackingSupplyIndex_ = totals.trackingSupplyIndex;
    }

    function mulFactor(uint n, uint factor) internal pure returns (uint) {
        return n * factor / FACTOR_SCALE;
    }

    error TimestampTooLarge();

    function presentValueSupply(uint64 baseSupplyIndex_, uint256 principalValue_) internal pure returns (uint256) {
        return principalValue_ * baseSupplyIndex_ / BASE_INDEX_SCALE;
    }

    function principalValueSupply(uint64 baseSupplyIndex_, uint256 presentValue_) internal pure returns (uint104) {
        return safe104((presentValue_ * BASE_INDEX_SCALE) / baseSupplyIndex_);
    }

    function getNowInternal() virtual internal view returns (uint40) {
        if (block.timestamp >= 2**40) revert TimestampTooLarge();
        return uint40(block.timestamp);
    }
}
