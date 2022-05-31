// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import { ISo } from "../Interfaces/ISo.sol";
import { LibAsset, IERC20 } from "../Libraries/LibAsset.sol";
import { ReentrancyGuard } from "../Helpers/ReentrancyGuard.sol";
import { ZeroPostSwapBalance } from "../Errors/GenericErrors.sol";
import { Swapper, LibSwap } from "../Helpers/Swapper.sol";

/// @title Generic Swap Facet
/// @author LI.FI (https://li.fi)
/// @notice Provides functionality for swapping through ANY APPROVED DEX
/// @dev Uses calldata to execute APPROVED arbitrary methods on DEXs
contract GenericSwapFacet is ISo, Swapper, ReentrancyGuard {
    /// Events ///

    event SoSwappedGeneric(
        bytes32 indexed transactionId,
        address fromAssetId,
        address toAssetId,
        uint256 fromAmount,
        uint256 toAmount
    );

    /// External Methods ///

    /// @notice Performs multiple swaps in one transaction
    /// @param _soData data used purely for tracking and analytics
    /// @param _swapData an array of swap related data for performing swaps before bridging
    function swapTokensGeneric(SoData calldata _soData, LibSwap.SwapData[] calldata _swapData)
        external
        payable
        nonReentrant
    {
        uint256 postSwapBalance = _executeAndCheckSwaps(_soData, _swapData);
        address receivingAssetId = _swapData[_swapData.length - 1].receivingAssetId;
        LibAsset.transferAsset(receivingAssetId, payable(msg.sender), postSwapBalance);

        emit SoSwappedGeneric(
            _soData.transactionId,
            _swapData[0].sendingAssetId,
            receivingAssetId,
            _swapData[0].fromAmount,
            postSwapBalance
        );
    }
}
