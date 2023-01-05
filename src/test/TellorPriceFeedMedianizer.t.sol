pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./geb/MockTreasury.sol";

import { TellorPriceFeedMedianizer } from  "../TellorPriceFeedMedianizer.sol";

import "geb-treasury-reimbursement/relayer/IncreasingRewardRelayer.sol";

import "../usingTellor/TellorPlayground.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract TellorPriceFeedMedianizerTest is DSTest {
    Hevm hevm;

    TellorPlayground aggregator;
    TellorPriceFeedMedianizer tellorMedianizer;
    IncreasingRewardRelayer relayer;
    MockTreasury treasury;
    DSToken rai;

    bytes queryData;
    bytes32 queryId;
    uint256 queryNonce;

    uint256 startTime                     = 1577836800;
    uint256 periodSize                    = 10;
    // uint256 periodSize                    = 10 + 15 minutes;
    uint256 callerReward                  = 15 ether;
    uint256 maxCallerReward               = 20 ether;
    uint256 initTokenAmount               = 100000000 ether;
    uint256 perSecondCallerRewardIncrease = 1.01E27;
    uint256 timeDelayAdjustment           = 915; // 15 minutes 15 seconds to ensure we are past the delay once a value is submitted

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        // Tellor Query Id
        queryData = abi.encode("SpotPrice", abi.encode("eth", "usd"));
        queryId = keccak256(queryData);
        queryNonce = 0;

        aggregator = new TellorPlayground();
        aggregator.submitValue(queryId, abi.encode(uint256(120 * 10**9)), queryNonce++, queryData);  // update tellor a first time to ensure getDataBefore works

        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        // Create median
        tellorMedianizer = new TellorPriceFeedMedianizer(
          address(aggregator),
          queryId,
          periodSize
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(tellorMedianizer),
            address(treasury),
            callerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            periodSize
        );
        tellorMedianizer.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));
    }

    // function test_change_uint_params() public {
    //     tellorMedianizer.modifyParameters("periodSize", 5);
    //     assertEq(tellorMedianizer.periodSize(), 5);
    // }
    // function test_update_result_and_read() public {
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);

    //     tellorMedianizer.updateResult(address(this));
    //     assertEq(tellorMedianizer.read(), 1.1 ether);
    //     assertEq(tellorMedianizer.lastUpdateTime(), now);

    //     hevm.warp(now + tellorMedianizer.periodSize());
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(this));
    //     assertEq(tellorMedianizer.lastUpdateTime(), now);
    // }
    // function test_reward_caller_other_first_and_second_update() public {
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);

    //     // First update
    //     tellorMedianizer.updateResult(address(0x123));
    //     assertEq(rai.balanceOf(address(0x123)), callerReward);

    //     // Second update
    //     hevm.warp(now + tellorMedianizer.periodSize());
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(0x123));
    //     assertEq(rai.balanceOf(address(0x123)), callerReward * 2);
    // }
    // function test_reward_after_waiting_more_than_maxRewardIncreaseDelay() public {
    //     relayer.modifyParameters("maxRewardIncreaseDelay", periodSize * 4);

    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);

    //     // First update
    //     tellorMedianizer.updateResult(address(0x123));
    //     assertEq(rai.balanceOf(address(0x123)), callerReward);

    //     // Second update
    //     hevm.warp(now + tellorMedianizer.periodSize());
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(0x123));
    //     assertEq(rai.balanceOf(address(0x123)), callerReward * 2);

    //     // Third update
    //     hevm.warp(now + relayer.maxRewardIncreaseDelay() + 1);
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(0x123));
    //     assertEq(rai.balanceOf(address(0x123)), callerReward * 2 + maxCallerReward);
    // }
    // function test_reward_caller_null_param_first_update() public {
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);

    //     // First
    //     tellorMedianizer.updateResult(address(0));
    //     assertEq(rai.balanceOf(address(this)), callerReward);

    //     // Second
    //     hevm.warp(now + tellorMedianizer.periodSize());
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(0));
    //     assertEq(rai.balanceOf(address(this)), callerReward * 2);
    // }
    // function test_increased_reward_above_max_second_update() public {
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    
    //     // First
    //     tellorMedianizer.updateResult(address(0));
    //     assertEq(rai.balanceOf(address(this)), callerReward);

    //     // Second
    //     hevm.warp(now + tellorMedianizer.periodSize());
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(0));
    //     assertEq(rai.balanceOf(address(this)), callerReward * 2);

    //     // Third
    //     hevm.warp(now + 1000);
    //     aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
    //     tellorMedianizer.updateResult(address(0));
    //     assertEq(rai.balanceOf(address(this)), maxCallerReward + callerReward * 2);
    // }

    function test_reward_other_multiple_times() public {
        aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
        hevm.warp(now + timeDelayAdjustment);
        // First
        tellorMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward);

        // Second
        // hevm.warp(now + tellorMedianizer.periodSize());
        aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
        hevm.warp(now + timeDelayAdjustment);
        tellorMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward * 2);

        // for (uint i = 0; i < 10; i++) {
        //   hevm.warp(now + periodSize);
        //   aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
        //   tellorMedianizer.updateResult(address(0x123));
        // }

        // assertEq(rai.balanceOf(address(0x123)), callerReward * 12);
    }
    
    function testFail_read_when_stale() public {
        aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);

        tellorMedianizer.updateResult(address(this));
        assertEq(tellorMedianizer.read(), 1.1 ether);

        hevm.warp(now + periodSize * tellorMedianizer.staleThreshold() + 1);
        assertEq(tellorMedianizer.read(), 1.1 ether);
    }

    function test_update_base_reward_zero() public {
        aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
        relayer.modifyParameters("baseUpdateCallerReward", 0);
        hevm.warp(now + timeDelayAdjustment);
        tellorMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(this)), 0);
    }

    function test_get_result_with_validity_when_stale() public {
        aggregator.submitValue(queryId, abi.encode(uint(1.1 ether)), queryNonce++, queryData);
        // hevm.warp(now + timeDelayAdjustment);
        tellorMedianizer.updateResult(address(this));
        (uint256 price, bool valid) = tellorMedianizer.getResultWithValidity();
        assertEq(price, 1.1 ether);        
        assertTrue(valid);

        hevm.warp(now + periodSize * tellorMedianizer.staleThreshold() + 1);
        (price, valid) = tellorMedianizer.getResultWithValidity();
        assertEq(price, 1.1 ether);
        assertTrue(!valid);
    }
}
