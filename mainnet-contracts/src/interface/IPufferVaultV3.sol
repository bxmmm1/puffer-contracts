// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { IPufferVaultV2 } from "./IPufferVaultV2.sol";

/**
 * @title IPufferVaultV3
 * @author Puffer Finance
 * @custom:security-contact security@puffer.fi
 */
interface IPufferVaultV3 is IPufferVaultV2 {
    struct BridgingParams {
        uint128 rewardsAmount;
        uint64 startEpoch;
        uint64 endEpoch;
        bytes32 rewardsRoot;
        string rewardsURI;
    }

    event MintedAndBridgedRewards(
        uint128 rewardsAmount, uint64 startEpoch, uint64 endEpoch, bytes32 indexed rewardsRoot, string rewardsURI
    );

    function mintAndBridgeRewards(BridgingParams calldata params, uint256 slippage) external payable;
}
