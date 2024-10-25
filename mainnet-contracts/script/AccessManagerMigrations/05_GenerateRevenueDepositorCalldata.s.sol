// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { Script } from "forge-std/Script.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { ROLE_ID_DAO, ROLE_ID_OPERATIONS_MULTISIG, ROLE_ID_REVENUE_DEPOSITOR } from "../../script/Roles.sol";
import { PufferRevenueDepositor } from "../../src/PufferRevenueDepositor.sol";

contract GenerateRevenueDepositorCalldata is Script {
    function run(address revenueDepositorProxy, address operationsMultisig) public pure returns (bytes memory) {
        bytes[] memory calldatas = new bytes[](5);

        bytes4[] memory daoSelectors = new bytes4[](3);
        daoSelectors[0] = PufferRevenueDepositor.setRnoRewardsBps.selector;
        daoSelectors[1] = PufferRevenueDepositor.setTreasuryRewardsBps.selector;
        daoSelectors[2] = PufferRevenueDepositor.setRewardsDistributionWindow.selector;

        calldatas[0] =
            abi.encodeCall(AccessManager.setTargetFunctionRole, (revenueDepositorProxy, daoSelectors, ROLE_ID_DAO));

        bytes4[] memory revenueDepositorSelectors = new bytes4[](1);
        revenueDepositorSelectors[0] = PufferRevenueDepositor.depositRevenue.selector;

        calldatas[1] = abi.encodeCall(
            AccessManager.setTargetFunctionRole,
            (revenueDepositorProxy, revenueDepositorSelectors, ROLE_ID_REVENUE_DEPOSITOR)
        );

        calldatas[2] = abi.encodeCall(AccessManager.grantRole, (ROLE_ID_REVENUE_DEPOSITOR, operationsMultisig, 0));

        calldatas[3] = abi.encodeCall(AccessManager.labelRole, (ROLE_ID_REVENUE_DEPOSITOR, "Revenue Depositor"));

        bytes4[] memory opsMultisigSelectors = new bytes4[](2);
        opsMultisigSelectors[0] = PufferRevenueDepositor.removeRestakingOperator.selector;
        opsMultisigSelectors[1] = PufferRevenueDepositor.addRestakingOperators.selector;

        calldatas[4] = abi.encodeCall(
            AccessManager.setTargetFunctionRole,
            (revenueDepositorProxy, opsMultisigSelectors, ROLE_ID_OPERATIONS_MULTISIG)
        );

        bytes memory encodedMulticall = abi.encodeCall(Multicall.multicall, (calldatas));

        return encodedMulticall;
    }
}
