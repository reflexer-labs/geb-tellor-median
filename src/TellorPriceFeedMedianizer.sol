pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import "./usingTellor/UsingTellor.sol";

abstract contract IncreasingRewardRelayerLike {
    function reimburseCaller(address) virtual external;
}

contract TellorPriceFeedMedianizer is GebMath, UsingTellor {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "TellorPriceFeedMedianizer/account-not-authorized");
        _;
    }

    // --- Variables ---
    IncreasingRewardRelayerLike public rewardRelayer;

    // Delay between updates after which the reward starts to increase
    uint256 public periodSize;
    // Latest median price
    uint256 private medianPrice;                    // [wad]
    // Timestamp of the Tellor aggregator
    uint256 public tellorAggregatorTimestamp;
    // Last timestamp when the median was updated
    uint256 public  lastUpdateTime;                 // [unix timestamp]
    // Multiplier for the Tellor price feed in order to scaled it to 18 decimals.
    uint8   public  multiplier = 0;

    // You want to change these every deployment
    uint256 public staleThreshold = 3;
    bytes32 public symbol         = "ethusd";

    // Tellor
    bytes32 public queryId;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(
      bytes32 parameter,
      address addr
    );
    event ModifyParameters(
      bytes32 parameter,
      uint256 val
    );
    event UpdateResult(uint256 medianPrice, uint256 lastUpdateTime);

    constructor(
      address tellorAddress_,
      bytes32 queryId_,
      uint256 periodSize_
    ) public UsingTellor(tellorAddress_) {
        require(tellorAddress_ != address(0), "TellorTWAP/null-tellor-address");
        require(queryId_ != bytes32(0), "TellorTWAP/null-tellor-query-id");
        require(periodSize_ > 0, "TellorPriceFeedMedianizer/null-period-size");

        authorizedAccounts[msg.sender] = 1;

        lastUpdateTime                 = now;
        periodSize                     = periodSize_;
        queryId                        = queryId_;

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("periodSize", periodSize);
    }

    // --- General Utils ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Administration ---
    /*
    * @notify Modify an uin256 parameter
    * @param parameter The name of the parameter to change
    * @param data The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "periodSize") {
          require(data > 0, "TellorPriceFeedMedianizer/null-period-size");
          periodSize = data;
        }
        else if (parameter == "staleThreshold") {
          require(data > 1, "TellorPriceFeedMedianizer/invalid-stale-threshold");
          staleThreshold = data;
        }
        else revert("TellorPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /*
    * @notify Modify an address parameter
    * @param parameter The name of the parameter to change
    * @param addr The new parameter address
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "TellorPriceFeedMedianizer/null-addr");
        if (parameter == "rewardRelayer") {
          rewardRelayer = IncreasingRewardRelayerLike(addr);
        }
        else revert("TellorPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Main Getters ---
    /**
    * @notice Fetch the latest medianResult or revert if is is invalid
    **/
    function read() external view returns (uint256) {
        require(both(medianPrice > 0, subtract(now, tellorAggregatorTimestamp) <= multiply(periodSize, staleThreshold)), "TellorPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianResult and whether it is valid or not
    **/
    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, both(medianPrice > 0, subtract(now, tellorAggregatorTimestamp) <= multiply(periodSize, staleThreshold)));
    }

    // --- Median Updates ---
    /*
    * @notify Update the median price
    * @param feeReceiver The address that will receive a SF payout for calling this function
    */
    event log(uint);
    function updateResult(address feeReceiver) external {
        // The relayer must not be null
        require(address(rewardRelayer) != address(0), "TellorPriceFeedMedianizer/null-reward-relayer");

        (bool success, bytes memory tellorResponse, uint256 aggregatorTimestamp) =
            getCurrentValue(queryId);
        require(success, "TellorTWAP/failed-to-query-tellor");

        uint256 aggregatorPrice = multiply(abi.decode(tellorResponse, (uint256)), 10 ** uint(multiplier));

        // Perform price and time checks
        require(aggregatorPrice > 0, "TellorPriceFeedMedianizer/invalid-price-feed");
        emit log(aggregatorTimestamp);
        emit log(tellorAggregatorTimestamp);
        require(both(aggregatorTimestamp > 0, aggregatorTimestamp > tellorAggregatorTimestamp), "TellorPriceFeedMedianizer/invalid-timestamp");

        // Update state
        medianPrice               = multiply(uint(aggregatorPrice), 10 ** uint(multiplier));
        tellorAggregatorTimestamp = aggregatorTimestamp;
        lastUpdateTime            = now;

        // Emit the event
        emit UpdateResult(medianPrice, lastUpdateTime);

        // Get final fee receiver
        address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

        // Send the reward
        rewardRelayer.reimburseCaller(finalFeeReceiver);
    }
}
