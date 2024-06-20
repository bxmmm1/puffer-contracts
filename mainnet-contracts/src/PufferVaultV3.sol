// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { PufferVaultV2 } from "./PufferVaultV2.sol";
import { IStETH } from "./interface/Lido/IStETH.sol";
import { ILidoWithdrawalQueue } from "./interface/Lido/ILidoWithdrawalQueue.sol";
import { IEigenLayer } from "./interface/EigenLayer/IEigenLayer.sol";
import { IStrategy } from "./interface/EigenLayer/IStrategy.sol";
import { IDelegationManager } from "./interface/EigenLayer/IDelegationManager.sol";
import { IWETH } from "./interface/Other/IWETH.sol";
import { IPufferVaultV3 } from "./interface/IPufferVaultV3.sol";
import { IPufferOracle } from "./interface/IPufferOracle.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableMap } from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IConnext } from "./interface/Connext/IConnext.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IXERC20Lockbox } from "./interface/IXERC20Lockbox.sol";

/**
 * @title PufferVaultV3
 * @author Puffer Finance
 * @custom:security-contact security@puffer.fi
 */
contract PufferVaultV3 is PufferVaultV2, IPufferVaultV3 {
    // The _CONNEXT contract on the origin domain.
    IConnext public immutable _CONNEXT;
    // The token to be paid on this domain
    IERC20 public immutable XTOKEN;
    IXERC20Lockbox LOCKBOX;
    uint32 public immutable _DESTINATION_DOMAIN;
    address public immutable L2_REWARD_MANAGER;

    constructor(
        IStETH stETH,
        IWETH weth,
        ILidoWithdrawalQueue lidoWithdrawalQueue,
        IStrategy stETHStrategy,
        IEigenLayer eigenStrategyManager,
        IPufferOracle oracle,
        IDelegationManager delegationManager,
        address connext,
        address _token,
        address xToken,
        address lockBox,
        uint32 destinationDomain,
        address l2RewardManager
    ) PufferVaultV2(stETH, weth, lidoWithdrawalQueue, stETHStrategy, eigenStrategyManager, oracle, delegationManager) {
        _CONNEXT = IConnext(connext);
        XTOKEN = IERC20(xToken);
        _DESTINATION_DOMAIN = destinationDomain;
        LOCKBOX = IXERC20Lockbox(lockBox);
        L2_REWARD_MANAGER = l2RewardManager;
        _disableInitializers();
    }

    receive() external payable virtual override { }

    function mintAndBridgeRewards(BridgingParams calldata params, uint256 slippage) external payable restricted {
        super.mint(params.rewardsAmount, address(this));

        approve(address(LOCKBOX), params.rewardsAmount);

        LOCKBOX.deposit(params.rewardsAmount);

        // This contract approves transfer to Connext
        XTOKEN.approve(address(_CONNEXT), params.rewardsAmount);

        // Encode calldata for the target contract call
        bytes memory callData = abi.encode(params);

        _CONNEXT.xcall{ value: msg.value }(
            _DESTINATION_DOMAIN, // _destination: Domain ID of the destination chain
            L2_REWARD_MANAGER, // _to: address of the target contract
            address(XTOKEN), // _asset: address of the token contract
            msg.sender, // _delegate: address that can revert or forceLocal on destination
            params.rewardsAmount, // _amount: amount of tokens to transfer
            slippage, // _slippage: max slippage the user will accept in BPS (e.g. 300 = 3%)
            callData // _callData: the encoded calldata to send
        );

        emit MintedAndBridgedRewards(
            params.rewardsAmount, params.startEpoch, params.endEpoch, params.rewardsProof, params.rewardsURI
        );
    }

    function _authorizeUpgrade(address newImplementation) internal virtual override restricted { }
}
