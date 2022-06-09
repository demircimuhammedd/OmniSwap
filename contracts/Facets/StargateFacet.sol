// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {LibAsset, IERC20} from "../Libraries/LibAsset.sol";
import {ISo} from "../Interfaces/ISo.sol";
import {IStargate} from "../Interfaces/IStargate.sol";
import {IStargateReceiver} from "../Interfaces/IStargateReceiver.sol";
import {LibDiamond} from "../Libraries/LibDiamond.sol";
import {ReentrancyGuard} from "../Helpers/ReentrancyGuard.sol";
import {InvalidAmount, CannotBridgeToSameNetwork, NativeValueWithERC, InvalidConfig} from "../Errors/GenericErrors.sol";
import {Swapper, LibSwap} from "../Helpers/Swapper.sol";
import {ILibSoFee} from "../Interfaces/ILibSoFee.sol";

/// @title Stargate Facet
/// @author SoSwap
/// @notice Provides functionality for bridging through Stargate
contract StargateFacet is ISo, Swapper, ReentrancyGuard, IStargateReceiver {
    /// Storage ///

    bytes32 internal constant NAMESPACE =
        hex"2bd10e5dcb5694caec513d6d8fa1fd90f6a026e0e9320d7b6e2f8e49b93270d1"; //keccak256("com.so.facets.stargate");

    struct Storage {
        address stargate; // stargate route address
        uint16 srcStargateChainId; // The stargate chain id of the source/current chain
    }

    /// Types ///

    struct StargateData {
        uint256 srcStargatePoolId; // The stargate pool id of the source chain
        address srcStargateToken; // The stargate pool id of the source chain
        uint16 dstStargateChainId; // The stargate chain id of the destination chain
        uint256 dstStargatePoolId; // The stargate pool id of the destination chain
        uint256 minAmount; // The stargate min amount
        IStargate.lzTxObj lzTxParams; // destination gas for sgReceive
        address payable dstSoDiamond; // destination SoDiamond address
    }

    /// Events ///

    event StargateInitialized(address stargate, uint256 chainId);

    /// Init ///

    /// @notice Initializes local variables for the Stargate facet
    /// @param _stargate address of the canonical Stargate router contract
    /// @param _chainId chainId of this deployed contract
    function initStargate(address _stargate, uint16 _chainId) external {
        LibDiamond.enforceIsContractOwner();
        if (_stargate == address(0)) revert InvalidConfig();
        Storage storage s = getStorage();
        s.stargate = _stargate;
        s.srcStargateChainId = _chainId;
        emit StargateInitialized(_stargate, _chainId);
    }

    /// External Methods ///

    /// @notice Bridges tokens via Stargate
    function soSwapViaStargate(
        SoData calldata _soData,
        LibSwap.SwapData[] calldata _swapDataSrc,
        StargateData calldata _stargateData,
        LibSwap.SwapData[] calldata _swapDataDst
    ) external payable nonReentrant {
        bool _hasSourceSwap;
        bool _hasDestinationSwap;
        uint256 _bridgeAmount;
        if (_swapDataSrc.length == 0) {
            LibAsset.depositAsset(
                _stargateData.srcStargateToken,
                _soData.amount
            );
            _bridgeAmount = _soData.amount;
            _hasSourceSwap = false;
        } else {
            _bridgeAmount = this.executeAndCheckSwaps(_soData, _swapDataSrc);
            _hasSourceSwap = true;
        }
        uint256 _stargateValue = _getStargateValue(_soData);
        bytes memory _payload;
        if (_swapDataDst.length == 0) {
            _payload = abi.encode(_soData, bytes(""));
            _hasDestinationSwap = false;
        } else {
            _payload = abi.encode(_soData, abi.encode(_swapDataDst));
            _hasDestinationSwap = true;
        }

        _startBridge(_stargateData, _stargateValue, _bridgeAmount, _payload);

        emit SoTransferStarted(
            _soData.transactionId,
            "Stargate",
            _hasSourceSwap,
            _hasDestinationSwap,
            _soData
        );
    }

    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 _amount,
        bytes memory _payload
    ) external {
        (SoData memory _soData, bytes memory swapPayload) = abi.decode(
            _payload,
            (SoData, bytes)
        );

        if (gasleft() < 20000) revert("Not enough gas");
        uint256 _swapGas = gasleft() - 20000;
        try
            this.remoteSwap{gas: _swapGas}(
                _chainId,
                _srcAddress,
                _nonce,
                _token,
                _amount,
                _soData,
                swapPayload
            )
        {} catch (bytes memory reason) {
            LibAsset.transferAsset(_token, _soData.receiver, _amount);
            emit SoTransferFailed(_soData.transactionId, reason, _soData);
        }
    }

    function remoteSwap(
        uint16 _chainId,
        bytes calldata _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 _amount,
        SoData calldata _soData,
        bytes calldata swapPayload
    ) external {
        uint256 _soFee = _getSoFee(_amount);
        if (_soFee < _amount) {
            _amount = _amount - _soFee;
        }
        if (_soFee > 0) {
            LibAsset.transferAsset(
                _token,
                payable(LibDiamond.contractOwner()),
                _soFee
            );
        }
        if (swapPayload.length == 0) {
            LibAsset.transferAsset(_token, _soData.receiver, _amount);
            emit SoTransferCompleted(
                _soData.transactionId,
                _soData.receivingAssetId,
                _soData.receiver,
                _amount,
                block.timestamp,
                _soData
            );
        } else {
            LibSwap.SwapData[] memory _swapDataDst = abi.decode(
                swapPayload,
                (LibSwap.SwapData[])
            );
            _swapDataDst[0].fromAmount = _amount;
            _swapDataDst[0].callData = this.correctSwap(
                _swapDataDst[0].callData,
                _swapDataDst[0].fromAmount
            );

            try this.executeAndCheckSwaps(_soData, _swapDataDst) returns (
                uint256 _amountFinal
            ) {
                LibAsset.transferAsset(
                    _swapDataDst[_swapDataDst.length - 1].receivingAssetId,
                    _soData.receiver,
                    _amountFinal
                );
                emit SoTransferCompleted(
                    _soData.transactionId,
                    _soData.receivingAssetId,
                    _soData.receiver,
                    _amountFinal,
                    block.timestamp,
                    _soData
                );
            } catch (bytes memory reason) {
                LibAsset.transferAsset(_token, _soData.receiver, _amount);
                emit SoTransferFailed(_soData.transactionId, reason, _soData);
            }
        }
    }

    function encodePayload(
        SoData calldata _soData,
        LibSwap.SwapData[] calldata _swapDataDst
    ) external view returns (bytes memory) {
        return abi.encode(_soData, abi.encode(_swapDataDst));
    }

    function correctSwap(bytes calldata _data, uint256 _amount)
        external
        view
        returns (bytes memory)
    {
        bytes4 sig = bytes4(_data[:4]);
        (
            uint256 _amountIn,
            uint256 _amountOutMin,
            address[] memory _path,
            address _to,
            uint256 _deadline
        ) = abi.decode(
                _data[4:],
                (uint256, uint256, address[], address, uint256)
            );
        return
            abi.encodeWithSelector(
                sig,
                _amount,
                _amountOutMin,
                _path,
                _to,
                _deadline
            );
    }

    /// Private Methods ///

    function _getSoFee(uint256 _amount) private returns (uint256) {
        address _soFee = appStorage.gatewaySoFeeSelectors[address(this)];
        if (_soFee == address(0x0)) {
            return 0;
        } else {
            return ILibSoFee(_soFee).getFees(_amount);
        }
    }

    /// @dev Conatains the business logic for the bridge via Stargate
    function _startBridge(
        StargateData calldata _stargateData,
        uint256 _stargateValue,
        uint256 _bridgeAmount,
        bytes memory _payload
    ) private {
        Storage storage s = getStorage();
        address bridge = s.stargate;

        // Do Stargate stuff
        if (s.srcStargateChainId == _stargateData.dstStargateChainId)
            revert CannotBridgeToSameNetwork();

        if (LibAsset.isNativeAsset(_stargateData.srcStargateToken)) {
            revert("Stargate: not supported native asset!");
        } else {
            // Give Stargate approval to bridge tokens
            LibAsset.maxApproveERC20(
                IERC20(_stargateData.srcStargateToken),
                bridge,
                _bridgeAmount
            );

            IStargate(bridge).swap{value: _stargateValue}(
                _stargateData.dstStargateChainId,
                _stargateData.srcStargatePoolId,
                _stargateData.dstStargatePoolId,
                payable(msg.sender),
                _bridgeAmount,
                _stargateData.minAmount,
                _stargateData.lzTxParams,
                abi.encodePacked(_stargateData.dstSoDiamond),
                _payload
            );
        }
    }

    function _getStargateValue(SoData calldata _soData)
        private
        returns (uint256)
    {
        if (LibAsset.isNativeAsset(_soData.sendingAssetId)) {
            require(
                msg.value > _soData.amount,
                "Stargate value is not enough!"
            );
            return msg.value - _soData.amount;
        } else {
            return msg.value;
        }
    }

    /// @dev fetch local storage
    function getStorage() private pure returns (Storage storage s) {
        bytes32 namespace = NAMESPACE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := namespace
        }
    }
}
