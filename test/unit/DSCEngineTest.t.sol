// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemTo, address token, uint256 amount);

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant INVALID_AMOUNT_DSC_MINTED = 20000e18;
    uint256 public constant VALID_AMOUNT_DSC_MINTED = 10000e18;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;

    // Liquidator
    address public liquidator = makeAddr("liquidator");
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        // user approve engine to spend their weth
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMintDSC() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, VALID_AMOUNT_DSC_MINTED);
        vm.stopPrank();
        _;
    }
    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        // Now, health factor is OK
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, COLLATERAL_TO_COVER);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);
        engine.liquidate(weth, USER, AMOUNT_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    /////////////////////////
    // Constructor test /////
    /////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////
    // Price test /////
    ///////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 10 ether;
        // 2000 USD / 1ETH
        uint256 expectedUsd = 20000 ether;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // 2000 USD / 1ETH
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////////
    // Account Information test /////
    ////////////////////////////////
    function testGetAccountInfortion() public depositedCollateral {
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        uint256 expectedTotalDSCMinted = 0;
        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ////////////////////////////////
    // Deposit Collateral Test /////
    ////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllow.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        uint256 expectedTotalDSCMinted = 0;
        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    //////////////////////
    // Mint DSC Test /////
    //////////////////////
    function testMintZeroDSC() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testMintBreakHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 5e17));
        engine.mintDsc(INVALID_AMOUNT_DSC_MINTED);
        vm.stopPrank();
    }

    function testMintSuccessfully() public depositCollateralAndMintDSC {
        vm.startPrank(USER);
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        vm.stopPrank();
        assertEq(totalDSCMinted, VALID_AMOUNT_DSC_MINTED);
        assertEq(totalCollateralValueInUsd, engine.getAccountCollateralValue(USER));
    }

    ///////////////////
    // Burn DSC Test //
    ///////////////////
    function testBurnDSC() public depositCollateralAndMintDSC {
        uint256 amountDscBurned = 5000e18;
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(engine), amountDscBurned);
        engine.burnDsc(amountDscBurned);
        vm.stopPrank();
        uint256 expectedDsc = VALID_AMOUNT_DSC_MINTED - amountDscBurned;
        (uint256 totalDSCMinted,) = engine.getAccountInformation(USER);
        assertEq(totalDSCMinted, expectedDsc);
    }

    function testBurnDSCExceed() public depositCollateralAndMintDSC {
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(engine), INVALID_AMOUNT_DSC_MINTED);
        vm.expectRevert();
        engine.burnDsc(INVALID_AMOUNT_DSC_MINTED);
        vm.stopPrank();
    }

    /////////////////////////////
    // Redeem Collateral Test ///
    /////////////////////////////
    function testRedeemCollateralSuccessAndEmitEvent() public depositedCollateral {
        uint256 amountCollateralRedeem = 5 ether;
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, weth, amountCollateralRedeem);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, amountCollateralRedeem);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountCollateralRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralBreakHealthFactor() public depositCollateralAndMintDSC {
        uint256 amountCollateralRedeem = 5 ether;
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 5e17));
        engine.redeemCollateral(weth, amountCollateralRedeem);
        vm.stopPrank();
    }

    //////////////////////////////////////
    // DepositCollateralAndMintDSC Test //
    //////////////////////////////////////
    function testDepositCollateralAndMintDSCSuccessful() public depositCollateralAndMintDSC {
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        assertEq(totalDSCMinted, VALID_AMOUNT_DSC_MINTED);
        assertEq(totalCollateralValueInUsd, engine.getAccountCollateralValue(USER));
    }

    /////////////////////////////////////
    // RedeemCollateralForDSC Test //////
    /////////////////////////////////////
    function testRedeemCollateralForDSCSuccess() public depositCollateralAndMintDSC {
        uint256 amountDscBurned = 5000e18;
        uint256 amountCollateralRedeem = 5 ether;
        uint256 remainCollateral = AMOUNT_COLLATERAL - amountCollateralRedeem;
        uint256 expectedEemainDsc = VALID_AMOUNT_DSC_MINTED - amountDscBurned;
        vm.startPrank(USER);
        ERC20Mock(address(dsc)).approve(address(engine), amountDscBurned);
        engine.redeemCollateralForDSC(weth, amountCollateralRedeem, amountDscBurned);
        vm.stopPrank();
        assertEq(engine.getAccountCollateralValue(USER), engine.getUsdValue(weth, remainCollateral));
        (uint256 remainDsc,) = engine.getAccountInformation(USER);
        assertEq(remainDsc, expectedEemainDsc);
    }

    ///////////////////////
    // Liquidate Test /////
    ///////////////////////
    function testCantLiquidateGoodHealthFactor() public depositCollateralAndMintDSC{
        ERC20Mock(weth).mint(liquidator, COLLATERAL_TO_COVER);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintDSC(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, 100 ether);
        vm.stopPrank();
    }

    function testLiquidateSuccess() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / engine.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    
    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / engine.getLiquidationBonus());

        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

}
