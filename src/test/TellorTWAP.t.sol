pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./geb/MockTreasury.sol";

import { TellorTWAP } from  "../TellorTWAP.sol";

import "geb-treasury-reimbursement/relayer/IncreasingRewardRelayer.sol";

import "../usingTellor/TellorPlayground.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract TellorTWAPTest is DSTest {
    Hevm hevm;

    TellorPlayground aggregator;
    TellorTWAP tellorTWAP;
    IncreasingRewardRelayer relayer;
    MockTreasury treasury;
    DSToken rai;

    bytes queryData;
    bytes32 queryId;
    uint256 queryNonce;

    address alice = address(0x4567);
    address me;

    uint256 startTime                     = 1577836800;
    uint256 windowSize                    = 1 hours;
    uint256 maxWindowSize                 = 4 hours;
    uint256 baseCallerReward              = 15 ether;
    uint256 maxCallerReward               = 20 ether;
    uint256 initTokenAmount               = 100000000 ether;
    uint256 perSecondCallerRewardIncrease = 1000192559420674483977255848; // 100% over one hour
    uint8   granularity                   = 4;
    uint8   multiplier                    = 1;

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

        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          windowSize,
          maxWindowSize,
          multiplier,
          granularity
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(tellorTWAP),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            15 minutes
        );
        tellorTWAP.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));

        me = address(this);

        hevm.warp(now + tellorTWAP.periodSize());
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'mul-overflow');
    }

    // --- Utils ---
    uint[] _values;
    uint[] _intervals;

    // will loop through all the prices in the values array and warp between updates
    // the last interval is not warped (so the updates are fresh)
    // returns the TWAP for a given granularity (without accounting for large intervals; overflows are also unnacounted for)
    function simulateUpdates(uint[] memory values, uint[] memory intervals, uint8 granularity) internal returns (uint) {
        require(values.length == intervals.length);
        require(values.length > granularity);

        uint converterResultCumulative;
        uint periodStart;

        for (uint i = 0; i < values.length; i++) {
            // aggregator.modifyParameters(int256(values[i]), now);
            aggregator.submitValue(queryId, abi.encode(values[i]), queryNonce++, queryData);
            tellorTWAP.updateResult(alice);

            //check if within granularity
            if(i >= values.length - granularity)
                converterResultCumulative += values[i] * intervals[i - 1];

            if(i == values.length - granularity - 1)
                periodStart = now;

            if(i != values.length -1) hevm.warp(now + intervals[i]);
        }

        return converterResultCumulative / (now - periodStart);
    }

    // --- Tests ---
    function test_correct_setup() public {
        assertEq(tellorTWAP.authorizedAccounts(me), 1);
        assertEq(address(tellorTWAP.tellor()), address(aggregator));

        assertEq(tellorTWAP.tellorAggregatorTimestamp(), 0);
        assertEq(tellorTWAP.lastUpdateTime(),0);
        assertEq(tellorTWAP.converterResultCumulative(), 0);
        assertEq(tellorTWAP.windowSize(), windowSize);
        assertEq(tellorTWAP.maxWindowSize(), maxWindowSize);
        assertEq(tellorTWAP.updates(), 0);

        assertEq(uint(tellorTWAP.multiplier()), 1);
        assertEq(uint(tellorTWAP.granularity()), uint(granularity));

        assertEq(tellorTWAP.staleThreshold(), 3);
        assertEq(tellorTWAP.symbol(), "ethusd");
        assertEq(tellorTWAP.getObservationListLength(), 0);

        assertEq(address(tellorTWAP.rewardRelayer()), address(relayer));
    }
    function testFail_setup_null_aggregator() public {
        tellorTWAP = new TellorTWAP(
          address(0x0),
          queryId,
          windowSize,
          maxWindowSize,
          multiplier,
          granularity
        );
    }
    function testFail_setup_null_query_id() public {
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          bytes32(0),
          windowSize,
          maxWindowSize,
          multiplier,
          granularity
        );
    }
    function testFail_setup_null_granularity() public {
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          windowSize,
          maxWindowSize,
          multiplier,
          0
        );
    }
    function testFail_setup_null_multiplier() public {
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          windowSize,
          maxWindowSize,
          0,
          granularity
        );
    }
    function testFail_setup_null_window_size() public {
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          0,
          maxWindowSize,
          multiplier,
          granularity
        );
    }
    function testFail_setup_window_not_evenly_divisible() public {
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          windowSize,
          maxWindowSize,
          multiplier,
          27
        );
    }
    function test_change_max_window_size() public {
        tellorTWAP.modifyParameters("maxWindowSize", maxWindowSize + 1);

        assertEq(tellorTWAP.maxWindowSize(), maxWindowSize + 1);
    }
    function testFail_change_max_window_size_lower_than_window() public {
        tellorTWAP.modifyParameters("maxWindowSize", windowSize);
    }
    function test_change_stale_threshold() public {
        tellorTWAP.modifyParameters("staleThreshold", 2);

        assertEq(tellorTWAP.staleThreshold(), 2);
    }
    function testFail_change_stale_threshold_invalid() public {
        tellorTWAP.modifyParameters("staleThreshold", 1);
    }
    function testFail_read_before_passing_granularity() public {
        hevm.warp(now + 3599);

        tellorTWAP.updateResult(alice);

        uint medianPrice = tellorTWAP.read();
    }
    function test_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        tellorTWAP.updateResult(alice);
        (uint256 medianPrice, bool isValid) = tellorTWAP.getResultWithValidity();
        assertTrue(!isValid);
    }
    function test_update_treasury_throws() public {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        // Set treasury allowance
        revertTreasury.setTotalAllowance(address(relayer), uint(-1));
        revertTreasury.setPerBlockAllowance(address(relayer), uint(-1));

        // Change the treasury in the relayer
        relayer.modifyParameters("treasury", address(revertTreasury));

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        tellorTWAP.updateResult(alice);
        assertEq(rai.balanceOf(alice), 0);
    }
    function test_update_treasury_reward_treasury() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        uint treasuryBalance = rai.balanceOf(address(treasury));

        tellorTWAP.updateResult(address(treasury));

        assertEq(rai.balanceOf(address(treasury)), treasuryBalance);
        assertEq(rai.balanceOf(alice), 0);
    }
    function testFail_update_again_immediately() public {
        hevm.warp(now + 3599);
        tellorTWAP.updateResult(address(this));

        hevm.warp(now + 1);
        tellorTWAP.updateResult(address(this));
    }
    function testFail_update_result_aggregator_invalid_value() public {
        aggregator.submitValue(queryId, abi.encode(uint256(0)), queryNonce++, queryData);
        hevm.warp(now + 3599);
        tellorTWAP.updateResult(address(this));
    }
    function test_update_result() public {
        hevm.warp(now + 3599);

        tellorTWAP.updateResult(address(this));
        (uint timestamp, uint timeAdjustedResult) =
          tellorTWAP.tellorObservations(0);
        (uint256 medianPrice, bool isValid) = tellorTWAP.getResultWithValidity();
        uint256 converterResultCumulative = tellorTWAP.converterResultCumulative();

        assertEq(uint256(tellorTWAP.earliestObservationIndex()), 0);
        assertEq(converterResultCumulative, 120 * 10**9 * tellorTWAP.periodSize());
        assertEq(medianPrice, 120 * 10**9);
        assertTrue(!isValid);
        assertEq(timestamp, now);
        assertEq(timeAdjustedResult, 120 * 10**9 * tellorTWAP.periodSize());
    }
    function test_wait_more_than_maxUpdateCallerReward_since_last_update() public {
        relayer.modifyParameters("maxRewardIncreaseDelay", 6 hours);

        uint maxRewardDelay = 100;
        tellorTWAP.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward);

        aggregator.submitValue(queryId, abi.encode(uint256(130 * 10**9)), queryNonce++, queryData);
        hevm.warp(now + tellorTWAP.periodSize());

        tellorTWAP.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2);

        aggregator.submitValue(queryId, abi.encode(uint256(130 * 10**9)), queryNonce++, queryData);
        hevm.warp(now + tellorTWAP.periodSize() + relayer.maxRewardIncreaseDelay() + 30);
        tellorTWAP.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2 + maxCallerReward);

        aggregator.submitValue(queryId, abi.encode(uint256(130 * 10**9)), queryNonce++, queryData);
        hevm.warp(now + tellorTWAP.periodSize() + relayer.maxRewardIncreaseDelay() + 30);
        tellorTWAP.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), maxCallerReward);

        aggregator.submitValue(queryId, abi.encode(uint256(130 * 10**9)), queryNonce++, queryData);
        hevm.warp(now + tellorTWAP.periodSize() + relayer.maxRewardIncreaseDelay() + 300 weeks);
        tellorTWAP.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), maxCallerReward * 2);
    }
    function test_read_same_price() public {
        for (uint i = 0; i <= granularity * 4; i++) {
            _values.push(uint(120 * 10**9));
            _intervals.push(tellorTWAP.periodSize());
        }

        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, uint(120 * 10**9));
        assertEq(testMedian, tellorTWAP.read()); // check median result
    }
    function test_read_diff_price() public {
        for (uint i = 0; i <= granularity * 4; i++) {
            _values.push(uint(120 * 10**9));
            _intervals.push(tellorTWAP.periodSize());
        }

        _values.push(uint(130 * 10**9));
        _intervals.push(tellorTWAP.periodSize() * 2);

        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, tellorTWAP.read()); // check median result
    }
    function test_read_fuzz(uint[8] memory values, uint[8] memory intervals) public {
        relayer.modifyParameters("maxRewardIncreaseDelay", 5 * 52 weeks);

        for (uint i = 0; i < 8; i++) {
            // random values from 1 to 1001 gwei
            _values.push(((values[i] % 1000) + 1) * uint(10**9));
            // random values between period size up to two times the size of it
            _intervals.push(tellorTWAP.periodSize() + (intervals[i] % tellorTWAP.periodSize()));
        }

        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, tellorTWAP.read()); // check median result
    }
    function test_two_hour_twap() public {
        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        // Create the TWAP
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          2 hours,
          4 hours,
          multiplier,
          2
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(tellorTWAP),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            1 hours
        );
        tellorTWAP.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));
        hevm.warp(now + tellorTWAP.periodSize());

        // Update median
        hevm.warp(now + 10);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));
        (, bool isValid) = tellorTWAP.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));
        (, isValid) = tellorTWAP.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));
        (, isValid) = tellorTWAP.getResultWithValidity();
        assertTrue(isValid);

        // Checks
        (uint256 medianPrice,) = tellorTWAP.getResultWithValidity();
        assertEq(medianPrice, uint(120 * 10**9));

        assertEq(tellorTWAP.updates(), 3);
        assertEq(tellorTWAP.timeElapsedSinceFirstObservation(), 1 hours);
    }
    function test_two_hour_twap_massive_update_delay() public {
        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        // Create the TWAP
        tellorTWAP = new TellorTWAP(
          address(aggregator),
          queryId,
          2 hours,
          4 hours,
          multiplier,
          2
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(tellorTWAP),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            1 hours
        );
        relayer.modifyParameters("maxRewardIncreaseDelay", 6 hours);
        tellorTWAP.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));
        hevm.warp(now + tellorTWAP.periodSize());

        // Update median
        hevm.warp(now + 1 hours);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));

        hevm.warp(now + 1 hours);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));

        hevm.warp(now + 3650 days);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));

        // Checks
        (uint256 medianPrice, bool isValid) = tellorTWAP.getResultWithValidity();
        assertEq(medianPrice, 120000000000);
        assertTrue(!isValid);

        assertEq(tellorTWAP.updates(), 3);
        assertEq(tellorTWAP.timeElapsedSinceFirstObservation(), 3650 days);

        // Another update
        hevm.warp(now + 1 hours);
        aggregator.submitValue(queryId, abi.encode(120 * 10**9), queryNonce++, queryData);
        tellorTWAP.updateResult(address(this));

        // Checks
        (medianPrice, isValid) = tellorTWAP.getResultWithValidity();
        assertEq(medianPrice, 120000000000);
        assertTrue(isValid);
    }
}
