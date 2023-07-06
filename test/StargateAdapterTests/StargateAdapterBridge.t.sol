// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import {SushiXSwapV2} from "../../src/SushiXSwapV2.sol";
import {StargateAdapter} from "../../src/adapters/StargateAdapter.sol";
import {ISushiXSwapV2} from "../../src/interfaces/ISushiXSwapV2.sol";
import {IRouteProcessor} from "../../src/interfaces/IRouteProcessor.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IStargateFeeLibrary} from "../../src/interfaces/stargate/IStargateFeeLibrary.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../../utils/BaseTest.sol";
import "../../utils/RouteProcessorHelper.sol";

import {StdUtils} from "forge-std/StdUtils.sol";

contract SushiXSwapBaseTest is BaseTest {
    SushiXSwapV2 public sushiXswap;
    StargateAdapter public stargateAdapter;
    IRouteProcessor public routeProcessor;
    RouteProcessorHelper public routeProcessorHelper;

    IStargateFeeLibrary public stargateFeeLibrary;
    address public stargateUSDCPoolAddress;
    address public stargateETHPoolAddress;

    IWETH public weth;
    ERC20 public sushi;
    ERC20 public usdc;

    address constant NATIVE_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public operator = address(0xbeef);
    address public owner = address(0x420);
    address public user = address(0x4201);

    function setUp() public override {
        forkMainnet();
        super.setUp(); 

        weth = IWETH(constants.getAddress("mainnet.weth"));
        sushi = ERC20(constants.getAddress("mainnet.sushi"));
        usdc = ERC20(constants.getAddress("mainnet.usdc"));

        vm.deal(address(operator), 100 ether);
        deal(address(weth), address(operator), 100 ether);
        deal(address(usdc), address(operator), 1 ether);
        deal(address(sushi), address(operator), 1000 ether);

        routeProcessor = IRouteProcessor(
            constants.getAddress("mainnet.routeProcessor")
        );
        routeProcessorHelper = new RouteProcessorHelper(
            constants.getAddress("mainnet.v2Factory"),
            constants.getAddress("mainnet.v3Factory"),
            address(routeProcessor),
            address(weth)
        );

        stargateFeeLibrary = IStargateFeeLibrary(
            constants.getAddress("mainnet.stargateFeeLibrary")
        );
        stargateUSDCPoolAddress = constants.getAddress(
            "mainnet.stargateUSDCPool"
        );
        stargateETHPoolAddress = constants.getAddress(
            "mainnet.stargateETHPool"
        );

        vm.startPrank(owner);
        sushiXswap = new SushiXSwapV2(routeProcessor, address(weth));

        // add operator as privileged
        sushiXswap.setPrivileged(operator, true);

        // setup stargate adapter
        stargateAdapter = new StargateAdapter(
            constants.getAddress("mainnet.stargateRouter"),
            constants.getAddress("mainnet.stargateWidget"),
            constants.getAddress("mainnet.sgeth"),
            constants.getAddress("mainnet.routeProcessor"),
            constants.getAddress("mainnet.weth")
        );
        sushiXswap.updateAdapterStatus(address(stargateAdapter), true);

        vm.stopPrank();
    }

    event Swap(
        uint16 chainId,
        uint256 dstPoolId,
        address from,
        uint256 amountSD,
        uint256 eqReward,
        uint256 eqFee,
        uint256 protocolFee,
        uint256 lpFee
    );

    // uint32 keeps it max amount to ~4294 usdc
    function testFuzz_BridgeERC20(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        vm.deal(user, 1 ether);
        deal(address(usdc), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        usdc.approve(address(sushiXswap), amount);

        (uint256 gasNeeded, ) = stargateAdapter.getFee(
            111, // dstChainId
            1, // functionType
            user, // receiver
            0, // gas
            0, // dustAmount
            "" // payload
        );

        (, uint256 eqFee, , , uint256 protocolFee, ) = stargateFeeLibrary.getFees(
            1, // srcPoolId
            1, // dstPoolId
            111, // dstChainId
            address(stargateAdapter), // from
            amount // amountSD
        );

        uint256 amountMin = amount - eqFee - protocolFee;

        vm.recordLogs();
        //todo: don't think we should be passing gasNeeded as value
        sushiXswap.bridge{value: gasNeeded}(
            ISushiXSwapV2.BridgeParams({
                adapter: address(stargateAdapter),
                tokenIn: address(usdc),
                amountIn: amount,
                to: address(0x0),
                adapterData: abi.encode(
                    111, // dstChainId - op
                    address(usdc), // token
                    1, // srcPoolId
                    1, // dstPoolId
                    amount, // amount
                    amountMin, // amountMin,
                    0, // dustAmount
                    user, // receiver
                    address(0x00), // to
                    0 // gas
                )
            }),
            "", // _swapPayload
            "" // _payloadData
        );

        // check balances post call
        assertEq(usdc.balanceOf(address(sushiXswap)), 0);
        assertEq(usdc.balanceOf(user), 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // first event from the stargate pool will be Swap
        for (uint i = 0; i < entries.length; i++) {
            // can get poolAddress from the stargate factory
            if (entries[i].emitter == stargateUSDCPoolAddress) {
                (
                    uint16 chainId,
                    uint256 dstPoolId,
                    address from,
                    uint256 amountSD,
                    uint256 eqReward,
                    uint256 _eqFeeEvent,
                    uint256 _protocolFeeEvent,
                    uint256 _lpFee
                ) = abi.decode(
                        entries[i].data,
                        (
                            uint16,
                            uint256,
                            address,
                            uint256,
                            uint256,
                            uint256,
                            uint256,
                            uint256
                        )
                    );

                assertEq(chainId, 111);
                assertEq(dstPoolId, 1);
                assertEq(from, address(stargateAdapter));
                assertEq(amountSD, amountMin);
                assertEq(_eqFeeEvent, eqFee);
                assertEq(_protocolFeeEvent, _protocolFeeEvent);
                break;
            }
        }
    }

    // uint64 keeps it max amount to ~18 weth
    function testFuzz_BridgeWETH(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(user, 1 ether);
        deal(address(weth), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        ERC20(address(weth)).approve(address(sushiXswap), amount);

        (uint256 gasNeeded, ) = stargateAdapter.getFee(
            111, // dstChainId
            1, // functionType
            user, // receiver
            0, // gas
            0, // dustAmount
            "" // payload
        );

        (, uint256 eqFee, , , uint256 protocolFee, ) = stargateFeeLibrary.getFees(
            13, // srcPoolId
            13, // dstPoolId
            111, // dstChainId
            address(stargateAdapter), // from
            amount // amountSD
        );

        uint256 amountMin = amount - eqFee - protocolFee;

        vm.recordLogs();
        //todo: don't think we should be passing gasNeeded as value
        sushiXswap.bridge{value: gasNeeded}(
            ISushiXSwapV2.BridgeParams({
                adapter: address(stargateAdapter),
                tokenIn: address(weth),
                amountIn: amount,
                to: address(0x0),
                adapterData: abi.encode(
                    111, // dstChainId - op
                    address(weth), // token
                    13, // srcPoolId
                    13, // dstPoolId
                    amount, // amount
                    amountMin, // amountMin,
                    0, // dustAmount
                    user, // receiver
                    address(0x00), // to
                    0 // gas
                )
            }),
            "", // _swapPayload
            "" // _payloadData
        );

        // check balances post call
        assertEq(weth.balanceOf(address(sushiXswap)), 0);
        assertEq(weth.balanceOf(user), 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // first event from the stargate pool will be Swap
        for (uint i = 0; i < entries.length; i++) {
            // can get poolAddress from the stargate factory
            if (entries[i].emitter == stargateETHPoolAddress) {
                (
                    uint16 chainId,
                    uint256 dstPoolId,
                    address from,
                    uint256 amountSD,
                    uint256 eqReward,
                    uint256 _eqFeeEvent,
                    uint256 _protocolFeeEvent,
                    uint256 _lpFee
                ) = abi.decode(
                        entries[i].data,
                        (
                            uint16,
                            uint256,
                            address,
                            uint256,
                            uint256,
                            uint256,
                            uint256,
                            uint256
                        )
                    );

                assertEq(chainId, 111);
                assertEq(dstPoolId, 13);
                assertEq(from, address(stargateAdapter));
                assertEq(amountSD, amountMin);
                assertEq(_eqFeeEvent, eqFee);
                assertEq(_protocolFeeEvent, _protocolFeeEvent);
                break;
            }
        }
    }

    function testBridgeNative() public {
        // bridge 1 eth
        vm.startPrank(operator);

        (uint256 gasNeeded, ) = stargateAdapter.getFee(
            111,
            1,
            address(operator),
            0,
            0,
            ""
        );

        uint256 valueToSend = gasNeeded + 1 ether;
        sushiXswap.bridge{value: valueToSend}(
            ISushiXSwapV2.BridgeParams({
                adapter: address(stargateAdapter),
                tokenIn: NATIVE_ADDRESS,
                amountIn: 1 ether,
                to: address(0x0),
                adapterData: abi.encode(
                    111, // dstChainId - op
                    NATIVE_ADDRESS, // token
                    13, // srcPoolId
                    13, // dstPoolId
                    1 ether, // amount
                    0, // amountMin,
                    0, // dustAmount
                    address(operator), // receiver
                    address(0x00), // to
                    0 // gas
                )
            }),
            "", // _swapPayload
            "" // _payloadData
        );
    }
}
