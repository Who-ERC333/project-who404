//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC404} from "../ERC404/ERC404.sol";
import {ERC5169} from "stl-contracts/ERC/ERC5169.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {PoolAddress} from "../utils/PoolAddress.sol";
import {TickMath} from "../utils/TickMath.sol";
import {PoolData} from "../structs/PoolData.sol";
import {MintParams, IncreaseLiquidityParams, DecreaseLiquidityParams, CollectParams} from "../structs/PositionParams.sol";
import {ExactInputSingleParams} from "../structs/RouterParams.sol";

abstract contract ERC333 is Ownable, ERC404, ERC5169 {
    event Initialize(PoolData poolData);
    event ReceiveTax(uint256 value);
    event ERC20Burn(uint256 value);
    event RefundETH(address sender, uint256 value);
    // event IncreaseLiquidity(uint256 amount);

    using Strings for uint256;

    string constant _JSON_FILE = ".json";

    // default settings
    uint256 public mintSupply = 10000; // max NFT count
    uint24 public taxPercent = 80000;
    address public initialMintRecipient; // the first token owner

    bool public initialized;
    PoolData public currentPoolData;

    /// @dev for the tick bar of ERC333
    int24 public tickThreshold;
    int24 public currentTick;
    uint256 public mintTimestamp;

    /// @dev Total tax in ERC-20 token representation
    uint256 public totalTax;

    address public positionManagerAddress;
    address public swapRouterAddress;

    /// @dev for compute arithmetic mean tick by observation
    uint32 constant TWAP_INTERVAL = 30 minutes;

    event BaseUriUpdate(string uri);

    string public baseURI;

    constructor(
        address initialOwner_,
        address initialMintRecipient_,
        uint256 mintSupply_,
        uint24 taxPercent_,
        string memory name_,
        string memory sym_,
        uint8 decimals_,
        uint8 ratio_
    ) ERC404(name_, sym_, decimals_, ratio_) Ownable(initialOwner_) {
        // init settings
        mintSupply = mintSupply_;
        taxPercent = taxPercent_;
        initialMintRecipient = initialMintRecipient_;

        // Do not mint the ERC721s to the initial owner, as it's a waste of gas.
        _setERC721TransferExempt(initialMintRecipient_, true);
        _mintERC20(initialMintRecipient_, mintSupply * units, false);
    }

    // Treat as ERC721 type, provide ERC20 interface in TokenScript
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC5169, ERC404) returns (bool) {
        return
            ERC5169.supportsInterface(interfaceId) ||
            ERC404.supportsInterface(interfaceId);
    }

    // ERC-5169
    function _authorizeSetScripts(
        string[] memory
    ) internal view override(ERC5169) onlyOwner {}

    // ======================================================================================================
    //
    // ERC333 overrides
    //
    // ======================================================================================================

    function initialize() external payable virtual;

    function _initialize(
        uint160 sqrtPriceX96,
        uint24 fee,
        address quoteToken,
        uint256 quoteTokenAmount,
        uint16 observationCardinalityNext,
        address positionManagerAddress_,
        address swapRouterAddress_
    ) internal virtual onlyOwner {
        require(!initialized, "has initialized");
        positionManagerAddress = positionManagerAddress_;
        swapRouterAddress = swapRouterAddress_;

        currentPoolData.quoteToken = quoteToken;
        currentPoolData.fee = fee;
        currentPoolData.sqrtPriceX96 = sqrtPriceX96;

        (address token0, address token1) = (address(this), quoteToken);
        (uint256 amount0, uint256 amount1) = (
            balanceOf[address(this)],
            quoteTokenAmount
        );
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (amount0, amount1) = (amount1, amount0);
        }
        _approveUniswap(token0, type(uint256).max);
        _approveUniswap(token1, type(uint256).max);

        // step1 create pool
        int24 tickSpacing;
        (
            currentPoolData.poolAddress,
            currentTick,
            tickSpacing
        ) = _initializePool(token0, token1, fee, sqrtPriceX96);
        require(
            currentPoolData.poolAddress != address(0) && tickSpacing != 0,
            "initialize pool failed"
        );
        tickThreshold = currentTick;

        currentPoolData.tickLower = (tickThreshold / tickSpacing) * tickSpacing;
        if (tickThreshold < 0) {
            currentPoolData.tickLower -= 60;
        }
        currentPoolData.tickUpper =
            (TickMath.MAX_TICK / tickSpacing) *
            tickSpacing;

        // step2 increase observation cardinality
        if (observationCardinalityNext > 0) {
            bool success = _initializeObservations(
                currentPoolData.poolAddress,
                observationCardinalityNext
            );
            require(success, "initialize observations failed");
        }

        // step3 create liquidity
        (
            currentPoolData.positionId,
            currentPoolData.liquidity,
            ,

        ) = _initializeLiquidity(
            token0,
            token1,
            fee,
            amount0,
            amount1,
            currentPoolData.tickLower,
            currentPoolData.tickUpper,
            address(this)
        );
        require(currentPoolData.positionId != 0, "initialize liquidity failed");
        mintTimestamp = block.timestamp;

        initialized = true;
        emit Initialize(currentPoolData);
    }

    /// @notice Explain to an end user what this does
    /// @dev Explain to a developer any extra details
    function _getCurrentTokenTick() internal virtual returns (int24) {
        if (!initialized) {
            return tickThreshold;
        }

        // Call uniswapV3Pool.slot0
        // 0x3850c7bd: keccak256(slot0())
        (bool success0, bytes memory data0) = currentPoolData
            .poolAddress
            .staticcall(abi.encodeWithSelector(0x3850c7bd));
        if (!success0) {
            return tickThreshold;
        }

        // Decode `Slot` from returned data
        (, int24 tick, uint16 index, uint16 cardinality, , , ) = abi.decode(
            data0,
            (uint160, int24, uint16, uint16, uint16, uint8, bool)
        );

        uint32 delta = TWAP_INTERVAL;
        if (uint32(block.timestamp - mintTimestamp) < delta) {
            return tick;
        }

        uint32[] memory secondsTwapIntervals = new uint32[](2);
        secondsTwapIntervals[0] = delta;
        secondsTwapIntervals[1] = 0;

        // Call uniswapV3Pool.observe
        // 0x883bdbfd: keccak256(observe(uint32[]))
        // require(pools[poolFee] != address(0), "Pool must init");
        (bool success, bytes memory data) = currentPoolData
            .poolAddress
            .staticcall(
                abi.encodeWithSelector(0x883bdbfd, secondsTwapIntervals)
            );

        if (!success) {
            return tick;
        }

        // Decode `tickCumulatives` from returned data
        (int56[] memory tickCumulatives, ) = abi.decode(
            data,
            (int56[], uint160[])
        );

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        tick = int24(tickCumulativesDelta / int56(uint56(delta)));
        // Always round to negative infinity
        if (
            tickCumulativesDelta < 0 &&
            (tickCumulativesDelta % int56(uint56(delta)) != 0)
        ) tick--;

        return tick;
    }

    function _approveUniswap(
        address token,
        uint256 amount
    ) internal virtual returns (bool) {
        if (amount == 0) {
            return true;
        }
        if (token == address(this)) {
            allowance[address(this)][positionManagerAddress] = amount;
            allowance[address(this)][swapRouterAddress] = amount;
            return true;
        }

        // Approve the position manager
        // Call approve
        // 0x095ea7b3: keccak256(approve(address,uint256))
        (bool success0, ) = token.call(
            abi.encodeWithSelector(0x095ea7b3, positionManagerAddress, amount)
        );

        (bool success1, ) = token.call(
            abi.encodeWithSelector(0x095ea7b3, swapRouterAddress, amount)
        );
        return success0 && success1;
    }

    function _initializePool(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    )
        internal
        virtual
        returns (address poolAddress, int24 tick, int24 tickSpacing)
    {
        // Call position manager createAndInitializePoolIfNecessary
        // 0x13ead562: keccak256(createAndInitializePoolIfNecessary(address,address,uint24,uint160))
        (bool success0, bytes memory data0) = positionManagerAddress.call(
            abi.encodeWithSelector(
                0x13ead562,
                token0,
                token1,
                fee,
                sqrtPriceX96
            )
        );
        // If createAndInitializePoolIfNecessary hasn't reverted
        if (!success0) {
            return (address(0), 0, 0);
        }
        // Decode `address` from returned data
        poolAddress = abi.decode(data0, (address));

        // Call uniswapV3Pool.slot0
        // 0x3850c7bd: keccak256(slot0())
        (bool success1, bytes memory data1) = poolAddress.staticcall(
            abi.encodeWithSelector(0x3850c7bd)
        );
        if (!success1) {
            return (address(0), 0, 0);
        }
        // Decode `Slot` from returned data
        (, tick, , , , , ) = abi.decode(
            data1,
            (uint160, int24, uint16, uint16, uint16, uint8, bool)
        );

        // Call uniswapV3Pool.tickSpacing
        // 0xd0c93a7c: keccak256(tickSpacing())
        (bool success2, bytes memory data2) = poolAddress.staticcall(
            abi.encodeWithSelector(0xd0c93a7c)
        );
        if (!success2) {
            return (address(0), 0, 0);
        }
        tickSpacing = abi.decode(data2, (int24));
    }

    function _initializeObservations(
        address poolAddress,
        uint16 observationCardinalityNext
    ) internal virtual returns (bool) {
        // Call pool increaseObservationCardinalityNext
        // 0x32148f67: keccak256(increaseObservationCardinalityNext(uint16))
        (bool success, ) = poolAddress.call(
            abi.encodeWithSelector(0x32148f67, observationCardinalityNext)
        );
        return success;
    }

    function _initializeLiquidity(
        address token0,
        address token1,
        uint24 fee,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper,
        address recipient
    )
        internal
        virtual
        returns (
            uint256 positionId,
            uint128 liquidity,
            uint256 amount0Used,
            uint256 amount1Used
        )
    {
        MintParams memory params = MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp
        });
        // Call position manager mint
        // 0x88316456: keccak256(mint((address,address,uint24,int24,int24,uint256,
        // uint256,uint256,uint256,address,uint256)))
        (bool success, bytes memory data) = positionManagerAddress.call(
            abi.encodeWithSelector(0x88316456, params)
        );

        // If mint hasn't reverted
        if (success) {
            // Decode `(uint256, uint128, uint256, uint256)` from returned data
            (positionId, liquidity, amount0Used, amount1Used) = abi.decode(
                data,
                (uint256, uint128, uint256, uint256)
            );
        }
    }

    function _exactInputSingle(
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut) {
        ExactInputSingleParams memory params = ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: currentPoolData.fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            deadline: block.timestamp
        });
        // Call position manager increaseLiquidity
        // 0x414bf389: keccak256(exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160)))
        (bool success, bytes memory data) = swapRouterAddress.call(
            abi.encodeWithSelector(0x414bf389, params)
        );

        // If exactInputSingle hasn't reverted
        if (success) {
            // Decode `(uint128, uint256, uint256)` from returned data
            amountOut = abi.decode(data, (uint256));
        }
    }

    function _increaseLiquidity(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1
    )
        internal
        virtual
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        IncreaseLiquidityParams memory params = IncreaseLiquidityParams({
            tokenId: positionId,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        // Call position manager increaseLiquidity
        // 0x219f5d17: keccak256(increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256)))
        (bool success, bytes memory data) = positionManagerAddress.call(
            abi.encodeWithSelector(0x219f5d17, params)
        );

        // If increaseLiquidity hasn't reverted
        if (success) {
            // Decode `(uint128, uint256, uint256)` from returned data
            (liquidity, amount0Used, amount1Used) = abi.decode(
                data,
                (uint128, uint256, uint256)
            );
        }
    }

    function _decreaseLiquidity(
        uint256 positionId,
        uint128 liquidity
    ) internal virtual returns (uint256 amount0, uint256 amount1) {
        DecreaseLiquidityParams memory params = DecreaseLiquidityParams({
            tokenId: positionId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        // Call position manager increaseLiquidity
        // 0x0c49ccbe: keccak256(decreaseLiquidity((uint256,uint128,uint256,uint256,uint256)))
        (bool success, bytes memory data) = positionManagerAddress.call(
            abi.encodeWithSelector(0x0c49ccbe, params)
        );

        // If decreaseLiquidity hasn't reverted
        if (success) {
            // Decode `(uint128, uint256, uint256)` from returned data
            (amount0, amount1) = abi.decode(data, (uint256, uint256));
        }
    }

    function _collect(
        uint256 positionId,
        address recipient
    ) internal virtual returns (uint256 amount0, uint256 amount1) {
        CollectParams memory params = CollectParams({
            tokenId: positionId,
            recipient: recipient,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        // Call position manager increaseLiquidity
        // 0xfc6f7865: keccak256(collect((uint256,address,uint128,uint128)))
        (bool success, bytes memory data) = positionManagerAddress.call(
            abi.encodeWithSelector(0xfc6f7865, params)
        );

        // If decreaseLiquidity hasn't reverted
        if (success) {
            // Decode `(uint128, uint256, uint256)` from returned data
            (amount0, amount1) = abi.decode(data, (uint256, uint256));
        }
    }

    function _getTaxOrBurned(
        address from_,
        address to_,
        uint256 value_
    ) internal virtual returns (uint256 tax, bool burned) {
        if (
            msg.sender == initialMintRecipient ||
            msg.sender == swapRouterAddress ||
            from_ == address(this) ||
            to_ == address(currentPoolData.poolAddress)
        ) {
            return (0, false);
        }

        // get token tick
        currentTick = _getCurrentTokenTick();
        if (currentTick > tickThreshold) {
            tax = (value_ * taxPercent) / 1000000;
        } else if (currentTick < tickThreshold) {
            burned = true;
        } else {
            // do someting if getCurrentTokenTick failed
        }
    }

    function _transferWithTax(
        address from_,
        address to_,
        uint256 value_
    ) public virtual returns (bool) {
        (uint256 tax, bool burned) = _getTaxOrBurned(from_, to_, value_);
        if (burned) {
            // burn from_ token,
            _transferERC20WithERC721(from_, address(0), value_);
            // refund the ETH value to the to_ address
            _refundETH(to_, value_);
            totalSupply -= value_;
            emit ERC20Burn(value_);
        } else if (tax > 0) {
            _transferERC20WithERC721(from_, to_, value_ - tax);
            _transferERC20WithERC721(from_, address(this), tax);
            totalTax += tax;
            emit ReceiveTax(tax);
        } else {
            // Transferring ERC-20s directly requires the _transfer function.
            _transferERC20WithERC721(from_, to_, value_);
        }

        return true;
    }

    function swapAndLiquify(uint256 amount) external virtual onlyOwner {
        require(
            amount <= (balanceOf[address(this)] / 2),
            "amount is too large"
        );

        // swap tokens for ETH
        uint256 quoteAmount = swapTokensForQuote(amount);

        if (quoteAmount > 0) {
            // add liquidity to uniswap
            addLiquidity(balanceOf[address(this)], quoteAmount);
        }
    }

    function liquifyAndCollect(uint128 liquidity) external virtual onlyOwner {
        require(
            liquidity <= (currentPoolData.liquidity),
            "liquidity is too large"
        );
        if (liquidity > 0) {
            subLiquidity(liquidity);
        }
        _collect(currentPoolData.positionId, initialMintRecipient);
    }

    function swapTokensForQuote(uint256 tokenAmount) private returns (uint256) {
        return
            _exactInputSingle(
                address(this),
                currentPoolData.quoteToken,
                address(this),
                tokenAmount
            );
    }

    function addLiquidity(uint256 thisAmount, uint256 quoteAmount) private {
        (address token0, address token1) = (
            address(this),
            currentPoolData.quoteToken
        );

        (uint256 amount0, uint256 amount1) = (thisAmount, quoteAmount);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            (amount0, amount1) = (amount1, amount0);
        }

        uint128 liquidity;
        (liquidity, amount0, amount1) = _increaseLiquidity(
            currentPoolData.positionId,
            amount0,
            amount1
        );
        if (liquidity > 0) {
            currentPoolData.liquidity += liquidity;
        }
    }

    function subLiquidity(uint128 liquidity) private {
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            currentPoolData.positionId,
            liquidity
        );
        if (amount0 > 0 || amount1 > 0) {
            currentPoolData.liquidity -= liquidity;
        }
    }

    /// @notice Function for ERC-20 transfers.
    /// @dev This function assumes the operator is attempting to transfer as ERC-20
    ///      given this function is only supported on the ERC-20 interface
    function transfer(
        address to_,
        uint256 value_
    ) public override returns (bool) {
        // Prevent burning tokens to 0x0.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        return _transferWithTax(msg.sender, to_, value_);
    }

    /// @notice Function for mixed transfers from an operator that may be different than 'from'.
    /// @dev This function assumes the operator is attempting to transfer an ERC-721
    ///      if valueOrId is less than or equal to current max id.
    function transferFrom(
        address from_,
        address to_,
        uint256 valueOrId_
    ) public override returns (bool) {
        // Prevent transferring tokens from 0x0.
        if (from_ == address(0)) {
            revert InvalidSender();
        }

        // Prevent burning tokens to 0x0.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        if (valueOrId_ <= _minted) {
            // Intention is to transfer as ERC-721 token (id).
            uint256 id = valueOrId_;

            if (from_ != _getOwnerOf(id)) {
                revert Unauthorized();
            }

            // Check that the operator is either the sender or approved for the transfer.
            if (
                msg.sender != from_ &&
                !isApprovedForAll[from_][msg.sender] &&
                msg.sender != getApproved[id]
            ) {
                revert Unauthorized();
            }

            // Transfer 1 * units ERC-20 and 1 ERC-721 token.
            _transferERC20(from_, to_, units);
            _transferERC721(from_, to_, id);
        } else {
            // Intention is to transfer as ERC-20 token (value).
            uint256 value = valueOrId_;
            uint256 allowed = allowance[from_][msg.sender];

            // Check that the operator has sufficient allowance.
            if (allowed != type(uint256).max) {
                allowance[from_][msg.sender] = allowed - value;
            }

            return _transferWithTax(from_, to_, value);
        }

        return true;
    }

    function _refundETH(address account, uint256 value) internal virtual {
        if (account == address(0)) {
            revert InvalidSender();
        }

        // Call balanceOf
        // 0x70a08231: keccak256(balanceOf(address))
        (bool success0, bytes memory data0) = currentPoolData
            .quoteToken
            .staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!success0) {
            return;
        }
        // Decode `uint256` from returned data
        uint256 totalWETHAmount = abi.decode(data0, (uint256));

        uint256 wethAmount = (value * totalWETHAmount) / totalSupply;

        // Call WETH transfer
        // 0xa9059cbb: keccak256(transfer(address,uint256))
        (bool success, ) = currentPoolData.quoteToken.call(
            abi.encodeWithSelector(0xa9059cbb, account, wethAmount)
        );

        // If transfer hasn't reverted
        if (success) {
            emit RefundETH(account, wethAmount);
        }
    }
}
