pragma solidity 0.6.7;

import "ds-test/test.sol";

import {TellorRelayer} from "../TellorRelayer.sol";

import "../usingTellor/TellorPlayground.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract TellorRelayerTest is DSTest {
    Hevm hevm;

    TellorPlayground aggregator;
    TellorRelayer relayer;

    bytes queryData;
    bytes32 queryId;
    uint256 queryNonce;

    uint256 startTime      = 1577836800;
    uint256 staleThreshold = 6 hours;
    uint256 timeDelay      = 900; // 15 minutes

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        // Tellor Query Id
        queryData = abi.encode("SpotPrice", abi.encode("eth", "usd"));
        queryId = keccak256(queryData);
        queryNonce = 0;

        aggregator = new TellorPlayground();
        address payable aggregatorAddress = address(uint160(address(aggregator)));
        relayer    = new TellorRelayer(aggregatorAddress, queryId, staleThreshold);
    }

    function test_change_uint_params() public {
        relayer.modifyParameters("staleThreshold", staleThreshold / 2);
        assertEq(relayer.staleThreshold(), staleThreshold / 2);
    }
    function testFail_read_null_price() public {
        aggregator.submitValue(queryId, abi.encode(uint256(0)), queryNonce++, queryData);

        relayer.read();
    }
    function testFail_read_stale_price() public {
        aggregator.submitValue(queryId, abi.encode(uint256(1 ether)), queryNonce++, queryData);
        hevm.warp(now + staleThreshold + 1);

        relayer.read();
    }
    function test_read() public {
        aggregator.submitValue(queryId, abi.encode(uint256(1 ether)), queryNonce++, queryData);
        hevm.warp(now + timeDelay + 1);
        relayer.read();
    }
    function test_getResultWithValidity_null_price() public {
        aggregator.submitValue(queryId, abi.encode(uint256(0)), queryNonce++, queryData);
        hevm.warp(now + timeDelay + 1);
        (uint median, bool validity) = relayer.getResultWithValidity();
        assertEq(median, 0);
        assertTrue(!validity);
    }
    function test_getResultWithValidity_stale() public {
        aggregator.submitValue(queryId, abi.encode(uint256(5)), queryNonce++, queryData);
        hevm.warp(now + staleThreshold + 1);

        (uint median, bool validity) = relayer.getResultWithValidity();
        assertEq(median, 5 * 10 ** uint(relayer.multiplier()));
        assertTrue(!validity);
    }
    function test_getResultWithValidity() public {
        aggregator.submitValue(queryId, abi.encode(uint256(5)), queryNonce++, queryData);
        hevm.warp(now + staleThreshold);

        (uint median, bool validity) = relayer.getResultWithValidity();
        assertEq(median, 5 * 10 ** uint(relayer.multiplier()));
        assertTrue(validity);
    }
    function test_updateResult() public {
        relayer.updateResult(address(0x1));
    }
}