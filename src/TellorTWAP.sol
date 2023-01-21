pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import "./usingTellor/UsingTellor.sol";

abstract contract IncreasingRewardRelayerLike {
    function reimburseCaller(address) virtual external;
}

contract TellorTWAP is GebMath, UsingTellor {
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
        require(authorizedAccounts[msg.sender] == 1, "TellorTWAP/account-not-authorized");
        _;
    }

    // --- Variables ---
    IncreasingRewardRelayerLike public rewardRelayer;

    // Delay between updates after which the reward starts to increase
    uint256 public immutable periodSize;
    // Timestamp of the tellor aggregator
    uint256 public tellorAggregatorTimestamp;
    // Last timestamp when the median was updated
    uint256 public lastUpdateTime;                  // [unix timestamp]
    // Cumulative result
    uint256 public converterResultCumulative;
    // Latest result
    uint256 private medianResult;                   // [wad]
    // Time delay to get prices before (15 minutes)
    uint256 public constant timeDelay = 900;
    /**
      The ideal amount of time over which the moving average should be computed, e.g. 24 hours.
      In practice it can and most probably will be different than the actual window over which the contract medianizes.
    **/
    uint256 public immutable windowSize;
    // Maximum window size used to determine if the median is 'valid' (close to the real one) or not
    uint256 public maxWindowSize;
    // Total number of updates
    uint256 public updates;
    // Multiplier for the tellor result
    uint8   public multiplier = 1;
    // Number of updates in the window
    uint8   public immutable granularity;
    
    // You want to change these every deployment
    uint256 public staleThreshold = 3;
    bytes32 public constant symbol         = "ethusd";

    // Tellor
    bytes32 public immutable queryId;

    TellorObservation[] public tellorObservations;

    // --- Structs ---
    struct TellorObservation {
        uint timestamp;
        uint timeAdjustedResult;
    }

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
    event UpdateResult(uint256 result);

    constructor(
      address payable tellorAddress_,
      bytes32 queryId_,
      uint256 windowSize_,
      uint256 maxWindowSize_,
      uint8   multiplier_,
      uint8   granularity_
    ) public UsingTellor(tellorAddress_) {
        require(tellorAddress_ != address(0), "TellorTWAP/null-tellor-address");
        require(queryId_ != bytes32(0), "TellorTWAP/null-tellor-query-id");
        require(multiplier_ >= 1, "TellorTWAP/null-multiplier");
        require(granularity_ > 1, 'TellorTWAP/null-granularity');
        require(windowSize_ > 0, 'TellorTWAP/null-window-size');
        require(
          (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
          'TellorTWAP/window-not-evenly-divisible'
        );

        authorizedAccounts[msg.sender] = 1;

        windowSize                     = windowSize_;
        maxWindowSize                  = maxWindowSize_;
        granularity                    = granularity_;
        multiplier                     = multiplier_;
        queryId                        = queryId_;

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("maxWindowSize", maxWindowSize);
    }

    // --- Boolean Utils ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- General Utils ---
    /**
    * @notice Returns the oldest observations (relative to the current index in the Uniswap/Converter lists)
    **/
    function getFirstObservationInWindow()
      private view returns (TellorObservation storage firstTellorObservation) {
        uint256 earliestObservationIndex = earliestObservationIndex();
        firstTellorObservation        = tellorObservations[earliestObservationIndex];
    }
    /**
      @notice It returns the time passed since the first observation in the window
    **/
    function timeElapsedSinceFirstObservation() public view returns (uint256) {
        if (updates > 1) {
          TellorObservation memory firstTellorObservation = getFirstObservationInWindow();
          return subtract(now, firstTellorObservation.timestamp);
        }
        return 0;
    }
    /**
    * @notice Returns the index of the earliest observation in the window
    **/
    function earliestObservationIndex() public view returns (uint256) {
        if (updates <= granularity) {
          return 0;
        }
        return subtract(updates, uint(granularity));
    }
    /**
    * @notice Get the observation list length
    **/
    function getObservationListLength() public view returns (uint256) {
        return tellorObservations.length;
    }

    // --- Administration ---
    /*
    * @notify Modify an uin256 parameter
    * @param parameter The name of the parameter to change
    * @param data The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "maxWindowSize") {
          require(data > windowSize, 'TellorTWAP/invalid-max-window-size');
          maxWindowSize = data;
        }
        else if (parameter == "staleThreshold") {
          require(data > 0, "TellorTWAP/invalid-stale-threshold");
          staleThreshold = data;
        }
        else revert("TellorTWAP/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /*
    * @notify Modify an address parameter
    * @param parameter The name of the parameter to change
    * @param addr The new parameter address
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        if (parameter == "rewardRelayer") {
          rewardRelayer = IncreasingRewardRelayerLike(addr);
        }
        else revert("TellorTWAP/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Main Getters ---
    /**
    * @notice Fetch the latest medianResult or revert if is is null
    **/
    function read() external view returns (uint256) {
        require(
          both(both(medianResult > 0, updates > granularity), timeElapsedSinceFirstObservation() <= maxWindowSize),
          "TellorTWAP/invalid-price-feed"
        );
        return multiply(medianResult, multiplier);
    }
    /**
    * @notice Fetch the latest medianResult and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (
          multiply(medianResult, multiplier),
          both(both(medianResult > 0, updates > granularity), timeElapsedSinceFirstObservation() <= maxWindowSize)
        );
    }
    // --- Median Updates ---
    /*
    * @notify Update the moving average
    * @param feeReceiver The address that will receive a SF payout for calling this function
    */
    function updateResult(address feeReceiver) external {
        require(address(rewardRelayer) != address(0), "TellorTWAP/null-reward-relayer");

        uint256 elapsedTime = (tellorObservations.length == 0) ?
          periodSize : subtract(now, tellorObservations[tellorObservations.length - 1].timestamp);

        // Check delay between calls
        require(elapsedTime >= periodSize, "TellorTWAP/wait-more");

        try this.getDataBefore(queryId, subtract(block.timestamp, timeDelay)) returns (bytes memory _value, uint256 _timestampRetrieved) {
          uint256 aggregatorResult     = abi.decode(_value, (uint256));

          require(aggregatorResult > 0, "TellorTWAP/invalid-feed-result");
          require(both(_timestampRetrieved > 0, _timestampRetrieved > tellorAggregatorTimestamp), "TellorTWAP/invalid-timestamp");

          // Get current first observation timestamp
          uint256 timeSinceFirst;
          if (updates > 0) {
            TellorObservation memory firstTellorObservation = getFirstObservationInWindow();
            timeSinceFirst = subtract(now, firstTellorObservation.timestamp);
          } else {
            timeSinceFirst = elapsedTime;
          }

          // Update the observations array
          updateObservations(elapsedTime, aggregatorResult);

          // Update var state
          medianResult              = converterResultCumulative / timeSinceFirst;
          updates                   = addition(updates, 1);
          tellorAggregatorTimestamp = _timestampRetrieved;
          lastUpdateTime            = now;

           emit UpdateResult(medianResult);

          // Get final fee receiver
          address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

          // Send the reward
          rewardRelayer.reimburseCaller(finalFeeReceiver);

        } catch {
            revert("TellorTWAP/failed-to-query-tellor");
        }

    }
    /**
    * @notice Push new observation data in the observation array
    * @param timeElapsedSinceLatest Time elapsed between now and the earliest observation in the window
    * @param newResult Latest result coming from tellor
    **/
    function updateObservations(
      uint256 timeElapsedSinceLatest,
      uint256 newResult
    ) internal {
        // Compute the new time adjusted result
        uint256 newTimeAdjustedResult = multiply(newResult, timeElapsedSinceLatest);
        // Add tellor observation
        tellorObservations.push(TellorObservation(now, newTimeAdjustedResult));
        // Add the new update
        converterResultCumulative = addition(converterResultCumulative, newTimeAdjustedResult);

        // Subtract the earliest update
        if (updates >= granularity) {
          TellorObservation memory TellorObservation = getFirstObservationInWindow();
          converterResultCumulative = subtract(converterResultCumulative, TellorObservation.timeAdjustedResult);
        }
    }
}
