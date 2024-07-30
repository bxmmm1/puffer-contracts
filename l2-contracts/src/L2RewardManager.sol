// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { AccessManagedUpgradeable } from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IPufferVaultV3 } from "mainnet-contracts/src/interface/IPufferVaultV3.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IL2RewardManager } from "./interface/IL2RewardManager.sol";
import { IXReceiver } from "@connext/interfaces/core/IXReceiver.sol";
import { L2RewardManagerStorage } from "./L2RewardManagerStorage.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { InvalidAmount, Unauthorized } from "mainnet-contracts/src/Errors.sol";

/**
 * @title L2RewardManager
 * @author Puffer Finance
 * @custom:security-contact security@puffer.fi
 */
contract L2RewardManager is
    IL2RewardManager,
    L2RewardManagerStorage,
    IXReceiver,
    AccessManagedUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public immutable XPUFETH;

    address public immutable L1_PUFFER_VAULT;

    constructor(address xPufETH, address l1PufferVault) {
        XPUFETH = IERC20(xPufETH);
        L1_PUFFER_VAULT = l1PufferVault;
        _disableInitializers();
    }

    modifier onlyPufferVault(address originSender) {
        if (originSender != address(L1_PUFFER_VAULT)) {
            revert Unauthorized();
        }
        _;
    }

    function initialize(address accessManager) external initializer {
        __AccessManaged_init(accessManager);
        _setClaimingDelay(12 hours);
    }

    /**
     * @inheritdoc IL2RewardManager
     */
    function isClaimed(uint256 startEpoch, uint256 endEpoch, address account) public view returns (bool) {
        RewardManagerStorage storage $ = _getRewardManagerStorage();
        return $.claimedRewards[_getIntervalId(startEpoch, endEpoch)][account];
    }

    /**
     * @inheritdoc IL2RewardManager
     */
    function getEpochRecord(uint256 startEpoch, uint256 endEpoch) external view returns (EpochRecord memory) {
        RewardManagerStorage storage $ = _getRewardManagerStorage();
        return $.epochRecords[_getIntervalId(startEpoch, endEpoch)];
    }

    /**
     * @inheritdoc IL2RewardManager
     */
    function xReceive(bytes32, uint256 amount, address, address originSender, uint32, bytes memory callData)
        external
        override(IL2RewardManager, IXReceiver)
        onlyPufferVault(originSender)
        restricted
        returns (bytes memory emptyReturnData)
    {
        IPufferVaultV3.BridgingParams memory bridgingParams = abi.decode(callData, (IPufferVaultV3.BridgingParams));

        if (bridgingParams.bridgingType == IPufferVaultV3.BridgingType.MintAndBridge) {
            _handleMintAndBridge(amount, bridgingParams.data);
        } else if (bridgingParams.bridgingType == IPufferVaultV3.BridgingType.SetClaimer) {
            _handleSetClaimer(bridgingParams.data);
        } else {
            revert InvalidBridgingType();
        }

        // Return empty bytes
        return "";
    }

    /**
     * @inheritdoc IL2RewardManager
     */
    function claimRewards(ClaimOrder[] calldata claimOrders) external {
        for (uint256 i = 0; i < claimOrders.length; i++) {
            if (isClaimed(claimOrders[i].startEpoch, claimOrders[i].endEpoch, claimOrders[i].account)) {
                revert AlreadyClaimed(claimOrders[i].startEpoch, claimOrders[i].endEpoch, claimOrders[i].account);
            }

            RewardManagerStorage storage $ = _getRewardManagerStorage();

            bytes32 intervalId = _getIntervalId(claimOrders[i].startEpoch, claimOrders[i].endEpoch);

            EpochRecord storage epochRecord = $.epochRecords[intervalId];

            if (block.timestamp < epochRecord.timeBridged + $.claimingDelay) {
                revert ClaimingLocked({
                    startEpoch: claimOrders[i].startEpoch,
                    endEpoch: claimOrders[i].endEpoch,
                    account: claimOrders[i].account,
                    lockedUntil: epochRecord.timeBridged + $.claimingDelay
                });
            }

            // Alice may run many Puffer validators in the same interval `totalETHEarned = sum(aliceValidators)`
            // The leaf is: keccak256(abi.encode(AliceAddress, startEpoch, endEpoch, totalETHEarned))
            bytes32 leaf = keccak256(
                bytes.concat(
                    keccak256(
                        abi.encode(
                            claimOrders[i].account,
                            claimOrders[i].startEpoch,
                            claimOrders[i].endEpoch,
                            claimOrders[i].amount
                        )
                    )
                )
            );
            if (!MerkleProof.verify(claimOrders[i].merkleProof, epochRecord.rewardRoot, leaf)) {
                revert InvalidProof();
            }

            // Mark it claimed and transfer the tokens
            $.claimedRewards[intervalId][claimOrders[i].account] = true;

            uint256 amountToTransfer = claimOrders[i].amount * epochRecord.ethToPufETHRate / 1 ether;

            address recipient = $.rewardsClaimers[claimOrders[i].account] == address(0)
                ? claimOrders[i].account
                : $.rewardsClaimers[claimOrders[i].account];

            // if the custom claimer is set, then transfer the tokens to the set claimer
            XPUFETH.safeTransfer(recipient, amountToTransfer);

            emit Claimed({
                recipient: recipient,
                account: claimOrders[i].account,
                startEpoch: claimOrders[i].startEpoch,
                endEpoch: claimOrders[i].endEpoch,
                amount: amountToTransfer
            });
        }
    }

    /**
     * @inheritdoc IL2RewardManager
     */
    function getRewardsClaimer(address account) external view returns (address) {
        RewardManagerStorage storage $ = _getRewardManagerStorage();
        return $.rewardsClaimers[account];
    }

    /**
     * @inheritdoc IL2RewardManager
     */
    function getClaimingDelay() external view returns (uint256) {
        RewardManagerStorage storage $ = _getRewardManagerStorage();
        return $.claimingDelay;
    }

    /**
     * @notice Sets the delay period for claiming rewards
     * @param delayPeriod The new delay period in seconds
     */
    function setDelayPeriod(uint256 delayPeriod) external restricted {
        _setClaimingDelay(delayPeriod);
    }

    function _handleMintAndBridge(uint256 amount, bytes memory data) internal {
        IPufferVaultV3.MintAndBridgeData memory params = abi.decode(data, (IPufferVaultV3.MintAndBridgeData));

        if (amount != (params.rewardsAmount * params.ethToPufETHRate / 1 ether)) {
            revert InvalidAmount();
        }

        RewardManagerStorage storage $ = _getRewardManagerStorage();

        // Store the rate and root
        $.epochRecords[_getIntervalId(params.startEpoch, params.endEpoch)] = EpochRecord({
            ethToPufETHRate: params.ethToPufETHRate,
            rewardRoot: params.rewardsRoot,
            timeBridged: block.timestamp
        });

        emit RewardRootAndRatePosted({
            rewardsAmount: params.rewardsAmount,
            ethToPufETHRate: params.ethToPufETHRate,
            startEpoch: params.startEpoch,
            endEpoch: params.endEpoch,
            root: params.rewardsRoot
        });
    }

    function _handleSetClaimer(bytes memory data) internal {
        IPufferVaultV3.SetClaimerParams memory claimerParams = abi.decode(data, (IPufferVaultV3.SetClaimerParams));

        RewardManagerStorage storage $ = _getRewardManagerStorage();
        $.rewardsClaimers[claimerParams.account] = claimerParams.claimer;

        emit ClaimerSet({ account: claimerParams.account, claimer: claimerParams.claimer });
    }

    function _getIntervalId(uint256 startEpoch, uint256 endEpoch) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(startEpoch, endEpoch));
    }

    function _setClaimingDelay(uint256 newDelay) internal restricted {
        if (newDelay < 6 hours) {
            revert InvalidDelayPeriod();
        }
        RewardManagerStorage storage $ = _getRewardManagerStorage();

        emit ClaimingDelayChanged({ oldDelay: $.claimingDelay, newDelay: newDelay });
        $.claimingDelay = newDelay;
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * Restricted access
     * @param newImplementation The address of the new implementation
     */
    // slither-disable-next-line dead-code
    function _authorizeUpgrade(address newImplementation) internal virtual override restricted { }
}
