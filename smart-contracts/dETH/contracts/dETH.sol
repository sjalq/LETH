// Listen up degen!
// This token is called dETH (death get it) because it will kill your hard earned money!
// This contract has no tests, it was tested manually a little on Kovan!
// This contract has no audit, so you're just plain insane if you give this thing a cent!
// I know the guy who wrote this and I wouldn't trust him with mission critical code!

pragma solidity ^0.5.17;

import "../../common.5/openzeppelin/token/ERC20/ERC20Detailed.sol";
import "../../common.5/openzeppelin/token/ERC20/ERC20.sol";
import "../../common.5/openzeppelin/GSN/Context.sol";
import "./DSMath.sol";
import "./DSProxy.sol";

contract IDSProxy
{
    function execute(address _target, bytes memory _data) public payable returns (bytes32);
}

contract IMCDSaverProxy
{
    function getCdpDetailedInfo(uint _cdpId) public view returns (uint collateral, uint debt, uint price, bytes32 ilk);
    function getRatio(uint _cdpId, bytes32 _ilk) public view returns (uint);
}

contract dETH is 
    Context, 
    ERC20Detailed, 
    ERC20,
    DSMath,
    DSProxy
{
    using SafeMath for uint;

    uint constant FEE_PERC = 9*10**15;      //   0.9%
    uint constant ONE_PERC = 10**16;        //   1.0% 
    uint constant HUNDRED_PERC = 10**18;    // 100.0%
    uint constant MIN_REDEMPTION_RATIO = 160;          // Minimum ration in normal percentages

    address payable public gulper;
    uint public cdpId;
    
    address public makerManager;
    address public ethGemJoin;

    IMCDSaverProxy public saverProxy;
    address public saverProxyActions;
    
    constructor(
            address payable _gulper,
            address _proxyCache,
            uint _cdpId,

            address _makerManager,
            address _ethGemJoin,
            
            IMCDSaverProxy _saverProxy,
            address _saverProxyActions,
            
            address _initialRecipient)
        public
        DSProxy(_proxyCache)
        ERC20Detailed("Derived Ether - Levered Ether", "dETH", 18)
    {
        gulper = _gulper;
        cdpId = _cdpId;

        makerManager = _makerManager;
        ethGemJoin = _ethGemJoin;
        saverProxy = _saverProxy;
        saverProxyActions = _saverProxyActions;
        
        _mint(_initialRecipient, getExcessCollateral());
    }

    function changeGulper(address payable _newGulper)
        public
        auth
    {
        gulper = _newGulper;
    }

    function giveCDPToDSProxy(address _dsProxy)
        public
        auth
    {
        bytes memory proxyCall = abi.encodeWithSignature(
            "give(address,uint256,address)", 
            makerManager, 
            cdpId, 
            _dsProxy);
        
        IDSProxy(address(this)).execute(saverProxyActions, proxyCall);
    }

    function getCollateral()
        public
        view
        returns(uint _price, uint _totalCollateral, uint _debt, uint _collateralDenominatedDebt, uint _excessCollateral)
    {
        (_totalCollateral, _debt, _price,) = saverProxy.getCdpDetailedInfo(cdpId);
        _collateralDenominatedDebt = rdiv(_debt, _price);
        _excessCollateral = sub(_totalCollateral, _collateralDenominatedDebt);
    }

    function getExcessCollateral()
        public
        view
        returns(uint _excessCollateral)
    {
        (,,,, _excessCollateral) = getCollateral();
    }

    function getRatio()
        public
        view
        returns(uint _ratio)
    {
        (,,,bytes32 ilk) = saverProxy.getCdpDetailedInfo(cdpId);
        _ratio = saverProxy.getRatio(cdpId, ilk);
    }

    function getMinRedemptionRatio()
        public
        pure
        returns(uint _minRatio)
    {
        // due to rdiv returning 10^9 less than one would intuitively expect, I've chosen to
        // set MIN_REDEMPTION_RATIO to 140 for clarity and rather just multiply it by 10^9 here so that
        // it is on the same order as getRatio() when comparing the two.
        _minRatio = DSMath.rdiv(MIN_REDEMPTION_RATIO.mul(10**9), 100);
    }

    function calculateIssuanceAmount(uint _suppliedCollateral)
        public
        view
        returns (
            uint _actualCollateralAdded,
            uint _fee,
            uint _tokensIssued)
    {
        _fee = _suppliedCollateral.mul(FEE_PERC).div(HUNDRED_PERC);
        _actualCollateralAdded = _suppliedCollateral.sub(_fee);
        uint tokenSupplyPerc = _actualCollateralAdded.mul(HUNDRED_PERC).div(getExcessCollateral());
        _tokensIssued = totalSupply().mul(tokenSupplyPerc).div(HUNDRED_PERC);
    }

    event Issued(
        address _receiver, 
        uint _suppliedCollateral,
        uint _fee,
        uint _actualCollateralAdded,
        uint _tokensIssued);

    function squanderMyEthForWorthlessBeans(address _receiver)
        payable
        public
    { 
        // Goals:
        // 1. deposits eth into the vault 
        // 2. gives the holder a claim on the vault for later withdrawal

        (uint collateralToLock, uint fee, uint tokensToIssue)  = calculateIssuanceAmount(msg.value);

        bytes memory proxyCall = abi.encodeWithSignature(
            "lockETH(address,address,uint256)", 
            makerManager, 
            ethGemJoin, 
            cdpId);
        
        // if something goes wrong, it's likely to go wrong here
        // likely because this method breaks because it is calling itself as if it's an
        // external call
        IDSProxy(address(this)).execute.value(collateralToLock)(saverProxyActions, proxyCall);
        
        (bool feePaymentSuccess,) = gulper.call.value(fee)("");
        require(feePaymentSuccess, "fee transfer to gulper failed");

        _mint(_receiver, tokensToIssue);
        
        emit Issued(
            _receiver, 
            msg.value, 
            fee, 
            collateralToLock, 
            tokensToIssue);
    }

    function calculateRedemptionValue(uint _tokensToRedeem)
        public
        view
        returns (
            uint _totalCollateralRedeemed, 
            uint _fee, 
            uint _collateralReturned)
    {
        // comment: a full check against the minimum ratio might be added in a future version
        // for now keep in mind that this function may return values greater than those that 
        // could be executed in one transaction. 
        require(_tokensToRedeem <= totalSupply(), "_tokensToRedeem exceeds totalSupply()");
        uint tokenSupplyPerc = _tokensToRedeem.mul(HUNDRED_PERC).div(totalSupply());
        _totalCollateralRedeemed = getExcessCollateral().mul(tokenSupplyPerc).div(HUNDRED_PERC);
        _fee = _totalCollateralRedeemed.mul(FEE_PERC).div(HUNDRED_PERC);
        _collateralReturned = _totalCollateralRedeemed.sub(_fee);
    }

    event Redeemed(
        address _redeemer,
        address _receiver, 
        uint _tokensRedeemed,
        uint _fee,
        uint _totalCollateralFreed,
        uint _collateralReturned);

    function redeem(uint _tokensToRedeem, address _receiver)
        public
    {
        // Goals:
        // 1. if the _tokensToRedeem being claimed does not drain the vault to below 160%
        // 2. pull out the amount of ether the senders' tokens entitle them to and send it to them

        (uint collateralToFree, uint fee, uint collateralToReturn) = calculateRedemptionValue(_tokensToRedeem);

        bytes memory proxyCall = abi.encodeWithSignature(
            "freeETH(address,address,uint256,uint256)",
            makerManager, 
            ethGemJoin, 
            cdpId,
            collateralToFree);
        IDSProxy(address(this)).execute(saverProxyActions, proxyCall);

        _burn(msg.sender, _tokensToRedeem);

        (bool feePaymentSuccess,) = gulper.call.value(fee)("");
        require(feePaymentSuccess, "fee transfer to gulper failed");
        
        (bool payoutSuccess,) = _receiver.call.value(collateralToReturn)("");
        require(payoutSuccess, "eth payment reverted");

        // this ensures that the CDP will be boostable by DefiSaver before it can be bitten
        require(getRatio() >= getMinRedemptionRatio(), "cannot violate collateral safety ratio");

        emit Redeemed(
            msg.sender,
            _receiver, 
            _tokensToRedeem,
            fee,
            collateralToFree,
            collateralToReturn);
    }

    function automate()
        public
        auth
    {
        // for reference - this function is called on the subscriptionsProxyV2: 
        // function subscribe(
        //     uint _cdpId, 
        //     uint128 _minRatio, 
        //     uint128 _maxRatio, 
        //     uint128 _optimalRatioBoost, 
        //     uint128 _optimalRatioRepay, 
        //     bool _boostEnabled, 
        //     bool _nextPriceEnabled, 
        //     address _subscriptions) 

        address subscriptionsProxyV2 = 0xd6f2125bF7FE2bc793dE7685EA7DEd8bff3917DD;
        address subscriptions = 0xC45d4f6B6bf41b6EdAA58B01c4298B8d9078269a; // since it's unclear if there's an official version of this on Kovan, this is hardcoded for mainnet

        bytes memory proxyCall = abi.encodeWithSignature(
            "subscribe(uint256,uint128,uint128,uint128,uint128,bool,bool,address)",
            cdpId, 
            170 * 10**16, 
            200 * 10**16,
            185 * 10**16,
            185 * 10**16,
            true,
            true,
            subscriptions);
        IDSProxy(address(this)).execute(subscriptionsProxyV2, proxyCall);
    }
    
    function () external payable { }
}