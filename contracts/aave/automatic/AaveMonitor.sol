pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "../../utils/GasBurner.sol";
import "./AaveMonitorProxy.sol";
import "./AaveSubscriptions.sol";
import "../../DS/DSMath.sol";
import "../../auth/AdminAuth.sol";
import "../../loggers/DefisaverLogger.sol";
import "../AaveSafetyRatio.sol";
import "../../exchange/SaverExchangeCore.sol";

/// @title Contract implements logic of calling boost/repay in the automatic system
contract AaveMonitor is AdminAuth, DSMath, AaveSafetyRatio, GasBurner {

    using SafeERC20 for ERC20;

    enum Method { Boost, Repay }

    uint public REPAY_GAS_TOKEN = 25;
    uint public BOOST_GAS_TOKEN = 20;

    uint constant public MAX_GAS_PRICE = 80000000000; // 80 gwei

    uint public REPAY_GAS_COST = 2200000;
    uint public BOOST_GAS_COST = 1700000;

    address public constant DEFISAVER_LOGGER = 0x5c55B921f590a89C1Ebe84dF170E655a82b62126;

    AaveMonitorProxy public aaveMonitorProxy;
    AaveSubscriptions public subscriptionsContract;
    address public aaveSaverProxy;

    DefisaverLogger public logger = DefisaverLogger(DEFISAVER_LOGGER);

    /// @dev Addresses that are able to call methods for repay and boost
    mapping(address => bool) public approvedCallers;

    modifier onlyApproved() {
        require(approvedCallers[msg.sender]);
        _;
    }

    /// @param _aaveMonitorProxy Proxy contracts that actually is authorized to call DSProxy
    /// @param _subscriptions Subscriptions contract for Aave positions
    /// @param _aaveSaverProxy Contract that actually performs Repay/Boost
    constructor(address _aaveMonitorProxy, address _subscriptions, address _aaveSaverProxy) public {
        approvedCallers[msg.sender] = true;

        aaveMonitorProxy = AaveMonitorProxy(_aaveMonitorProxy);
        subscriptionsContract = AaveSubscriptions(_subscriptions);
        aaveSaverProxy = _aaveSaverProxy;
    }

    /// @notice Bots call this method to repay for user when conditions are met
    /// @dev If the contract ownes gas token it will try and use it for gas price reduction
    /// @param _exData Exchange data
    /// @param _user The actual address that owns the Aave position
    function repayFor(
        SaverExchangeCore.ExchangeData memory _exData,
        address _user
    ) public payable onlyApproved burnGas(REPAY_GAS_TOKEN) {

        (bool isAllowed, uint ratioBefore) = canCall(Method.Repay, _user);
        require(isAllowed); // check if conditions are met

        uint256 gasCost = calcGasCost(REPAY_GAS_COST);

        aaveMonitorProxy.callExecute{value: msg.value}(
            _user,
            aaveSaverProxy,
            abi.encodeWithSignature(
                "repay((address,address,uint256,uint256,uint256,address,address,bytes,uint256),uint256)",
                _exData,
                gasCost
            )
        );

        (bool isGoodRatio, uint ratioAfter) = ratioGoodAfter(Method.Repay, _user);
        require(isGoodRatio); // check if the after result of the actions is good

        returnEth();

        logger.Log(address(this), _user, "AutomaticAaveRepay", abi.encode(ratioBefore, ratioAfter));
    }

    /// @notice Bots call this method to boost for user when conditions are met
    /// @dev If the contract ownes gas token it will try and use it for gas price reduction
    /// @param _exData Exchange data
    /// @param _user The actual address that owns the Aave position
    function boostFor(
        SaverExchangeCore.ExchangeData memory _exData,
        address _user
    ) public payable onlyApproved burnGas(BOOST_GAS_TOKEN) {

        (bool isAllowed, uint ratioBefore) = canCall(Method.Boost, _user);
        require(isAllowed); // check if conditions are met

        uint256 gasCost = calcGasCost(BOOST_GAS_COST);

        aaveMonitorProxy.callExecute{value: msg.value}(
            _user,
            aaveSaverProxy,
            abi.encodeWithSignature(
                "boost((address,address,uint256,uint256,uint256,address,address,bytes,uint256),uint256)",
                _exData,
                gasCost
            )
        );


        (bool isGoodRatio, uint ratioAfter) = ratioGoodAfter(Method.Boost, _user);
        require(isGoodRatio);  // check if the after result of the actions is good

        returnEth();

        logger.Log(address(this), _user, "AutomaticAaveBoost", abi.encode(ratioBefore, ratioAfter));
    }

/******************* INTERNAL METHODS ********************************/
    function returnEth() internal {
        // return if some eth left
        if (address(this).balance > 0) {
            msg.sender.transfer(address(this).balance);
        }
    }

/******************* STATIC METHODS ********************************/

    /// @notice Checks if Boost/Repay could be triggered for the CDP
    /// @dev Called by MCDMonitor to enforce the min/max check
    /// @param _method Type of action to be called
    /// @param _user The actual address that owns the Aave position
    /// @return Boolean if it can be called and the ratio
    function canCall(Method _method, address _user) public view returns(bool, uint) {
        bool subscribed = subscriptionsContract.isSubscribed(_user);
        AaveSubscriptions.AaveHolder memory holder = subscriptionsContract.getHolder(_user);

        // check if cdp is subscribed
        if (!subscribed) return (false, 0);

        // check if boost and boost allowed
        if (_method == Method.Boost && !holder.boostEnabled) return (false, 0);

        uint currRatio = getSafetyRatio(_user);

        if (_method == Method.Repay) {
            return (currRatio < holder.minRatio, currRatio);
        } else if (_method == Method.Boost) {
            return (currRatio > holder.maxRatio, currRatio);
        }
    }

    /// @dev After the Boost/Repay check if the ratio doesn't trigger another call
    /// @param _method Type of action to be called
    /// @param _user The actual address that owns the Aave position
    /// @return Boolean if the recent action preformed correctly and the ratio
    function ratioGoodAfter(Method _method, address _user) public view returns(bool, uint) {
        AaveSubscriptions.AaveHolder memory holder;

        holder= subscriptionsContract.getHolder(_user);

        uint currRatio = getSafetyRatio(_user);

        if (_method == Method.Repay) {
            return (currRatio < holder.maxRatio, currRatio);
        } else if (_method == Method.Boost) {
            return (currRatio > holder.minRatio, currRatio);
        }
    }

    /// @notice Calculates gas cost (in Eth) of tx
    /// @dev Gas price is limited to MAX_GAS_PRICE to prevent attack of draining user CDP
    /// @param _gasAmount Amount of gas used for the tx
    function calcGasCost(uint _gasAmount) public view returns (uint) {
        uint gasPrice = tx.gasprice <= MAX_GAS_PRICE ? tx.gasprice : MAX_GAS_PRICE;

        return mul(gasPrice, _gasAmount);
    }

/******************* OWNER ONLY OPERATIONS ********************************/

    /// @notice Allows owner to change gas cost for boost operation, but only up to 3 millions
    /// @param _gasCost New gas cost for boost method
    function changeBoostGasCost(uint _gasCost) public onlyOwner {
        require(_gasCost < 3000000);

        BOOST_GAS_COST = _gasCost;
    }

    /// @notice Allows owner to change gas cost for repay operation, but only up to 3 millions
    /// @param _gasCost New gas cost for repay method
    function changeRepayGasCost(uint _gasCost) public onlyOwner {
        require(_gasCost < 3000000);

        REPAY_GAS_COST = _gasCost;
    }

    /// @notice Adds a new bot address which will be able to call repay/boost
    /// @param _caller Bot address
    function addCaller(address _caller) public onlyOwner {
        approvedCallers[_caller] = true;
    }

    /// @notice Removes a bot address so it can't call repay/boost
    /// @param _caller Bot address
    function removeCaller(address _caller) public onlyOwner {
        approvedCallers[_caller] = false;
    }

    /// @notice If any tokens gets stuck in the contract owner can withdraw it
    /// @param _tokenAddress Address of the ERC20 token
    /// @param _to Address of the receiver
    /// @param _amount The amount to be sent
    function transferERC20(address _tokenAddress, address _to, uint _amount) public onlyOwner {
        ERC20(_tokenAddress).safeTransfer(_to, _amount);
    }

    /// @notice If any Eth gets stuck in the contract owner can withdraw it
    /// @param _to Address of the receiver
    /// @param _amount The amount to be sent
    function transferEth(address payable _to, uint _amount) public onlyOwner {
        _to.transfer(_amount);
    }
}
