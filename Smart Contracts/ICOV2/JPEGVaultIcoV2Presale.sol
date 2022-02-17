// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "./oracle/IJPEGVaultIcoOracle.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract JPEGVaultIcoV2Presale is ReentrancyGuard {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    // early Access to presale
    EnumerableSet.AddressSet private includePresale; // list of addresses that have access to presale 24 hours before;

    ERC20 private _earlyAccessToken; // sos token
    uint256 private _minAccessTokenBalance = 10000000000000000000000000;

    /* ICO parameters */
    uint256 private _rate;
    uint256 public minDeposit;
    uint256 public maxDeposit;
    uint256 public openingTime;
    uint256 public closingTime;
    uint256 public fundingTarget;

    /* storage */
    mapping(address => uint256) public balances;
    mapping(uint256 => bool) public requests;

    // The token being sold
    ERC20 private _token;

    // Address where funds are collected
    address payable private _wallet;

    // oracle address
    address private oracleAddress;
    IJPEGVaultIcoOracle oracleInstance;

    // Amount of wei raised
    uint256 private _weiRaised;
    uint256 private _totalJPEGRaised; // should be _weiRaised.mul(_rate) and should be equal to funding target for a filled presale

    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokensPurchased(
        address indexed purchaser,
        address indexed beneficiary,
        uint256 value,
        uint256 amount
    );
    event TokenClaimed(address indexed beneficiary, uint256 amount);
    event JPEGVaultICOExtended(uint256 closingTime, uint256 newClosingTime);
    event TotalRaisedUpdated(uint256 amount, uint256 id);
    event NewTotalWeiRaisedRequest(uint256 id, address oracleAddress);

    address private _admin;

    /**
     * @param rate Number of token units a buyer gets per wei
     * @dev The rate is the conversion between wei and the smallest and indivisible
     * @param wallet Address where collected funds will be forwarded to
     * @param tokenAddress Address of the token being sold
     * @param _oracleAddress Address of the oracle that handles updating the _totalJPEGRaised
     * @param rate This is the amount of Jpeg that can be claimed for 1 unit of the native currency (ETH|BNB)
     * @param _minDeposit the minimum amount of native Currency that can be deposited at a time
     * @param _maxDeposit the maximum amount of native Currency that can be deposited on this chain
     * @param _target the maximum amount of JPEGVaultDaoToken  that can be bought during sales
     */
    constructor(
        address admin,
        address payable wallet,
        address tokenAddress,
        address _oracleAddress,
        address earlyAccessToken,
        address[] memory presaleAddresses,
        uint256 rate,
        uint256 _minDeposit,
        uint256 _maxDeposit,
        uint256 _target
    ) {
        require(rate > 0, "rate is 0");
        require(wallet != address(0), "wallet is the zero address");
        require(admin != address(0), "Admin is the zero address");
        require(
            earlyAccessToken != address(0),
            "Presale access token is the zero address"
        );
        require(tokenAddress != address(0), "JPEGVaultICO is the zero address");
        require(
            _maxDeposit > _minDeposit,
            "Maximum deposit is less than minimum desposit."
        );
        require(_target > 0, "Invalid Funding target set.");

        for (uint256 i = 0; i < presaleAddresses.length; i++) {
            includePresale.add(presaleAddresses[i]);
        }

        _rate = rate;
        _wallet = wallet;
        _token = ERC20(tokenAddress);
        _earlyAccessToken = ERC20(earlyAccessToken);
        _admin = admin;
        maxDeposit = _maxDeposit;
        minDeposit = _minDeposit;
        fundingTarget = _target; // don't forget funding target should be the amount of JPEG budgeted for the presale.
        oracleAddress = _oracleAddress;
        oracleInstance = IJPEGVaultIcoOracle(oracleAddress);
    }

    /* Modifiers */
    modifier onlyWhileOpen() {
        require(isOpen(), "Sales is not currently on!");
        _;
    }

    modifier onlyWhileClosed() {
        require(hasClosed(), "Sales is currently on!");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, "Unauthorized sender");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracleAddress, "Unauthorized oracle");
        _;
    }

    /**
     * @dev fallback function ***DO NOT OVERRIDE***
     * Note that other contracts will transfer funds with a base gas stipend
     * of 2300, which is not enough to call depositToken. Consider calling
     * depositToken directly when purchasing tokens from a contract.
     */
    receive() external payable {
        depositToken(msg.sender);
    }

    /// @dev Admin can call this function to destroy the contract and send out all eth balance to admin address
    function destroy() external onlyAdmin {
        selfdestruct(payable(_admin));
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * This function has a non-reentrancy guard, so it shouldn't be called by
     * another `nonReentrant` function.
     * @param beneficiary Recipient of the token purchase
     */
    function depositToken(address beneficiary)
        public
        payable
        nonReentrant
    {
        uint256 weiAmount = msg.value;
        _preValidatePurchase(beneficiary, weiAmount);

        if (isEarlyAccessPeriod()) {
            _prevalidateEarlyPurchase(weiAmount);
        } else {
             require(isOpen(), "Sales is not opened");
        }

        uint256 _existingbalance = balances[beneficiary];
        uint256 _newBalance = _existingbalance.add(weiAmount);
        require(_newBalance <= maxDeposit, "Maximum deposit exceeded!!!");
        balances[beneficiary] = _newBalance;

        _weiRaised = _weiRaised.add(weiAmount);

        _forwardFunds();
        requestTotalWeiRaised();

        uint256 tokens = getTokenClaimable(weiAmount);
        emit TokensPurchased(msg.sender, beneficiary, weiAmount, tokens);
    }

    /**
     * @dev Withdraw tokens only after crowdsale ends.
     * @param beneficiary Whose tokens will be withdrawn.
     */
    function withdrawTokens(address beneficiary) public nonReentrant {
        // check if Ico is still opened
        require(hasClosed(), "JPEGVaultICO: not closed");

        uint256 amount = balances[beneficiary];
        require(amount > 0, "JPEGVaultICO: beneficiary is not due any tokens");

        uint256 tokenAmount = getTokenClaimable(balances[beneficiary]);

        balances[beneficiary] = 0;

        // transfer token to beneficiary
        _deliverTokens(beneficiary, tokenAmount);

        emit TokenClaimed(beneficiary, tokenAmount);
    }

    /// @notice function to send out all unclaimed JPEG tokens after Crowdsale
    /// @dev function to send out all unclaimed JPEG tokens after Crowdsale if balance is greater than zero
    function withdrawUnclaimed() external onlyWhileClosed onlyAdmin {
        uint256 balance = _token.balanceOf(address(this));
        require(balance > 0, "Contract has no JPEGToken left");
        _token.transfer(_admin, balance);
    }

    function _prevalidateEarlyPurchase(uint256 weiAmount) internal view {
        bool isJpegHolder = includePresale.contains(msg.sender);
        bool isEarlyAccessTokenHolder = _earlyAccessToken.balanceOf(
            msg.sender
        ) > _minAccessTokenBalance;
        require(isJpegHolder || isEarlyAccessTokenHolder, "You're not eligible to early presale");

        require(
            weiRaised().add(weiAmount).mul(_rate) <= fundingTarget.div(2),
            "Wei raised exceeds 50% of funding target"
        );
        require(
            _totalJPEGRaised.add(weiAmount.mul(_rate)) <= fundingTarget.div(2),
            "JPEGVaultDaoToken raised exceeds 50% of funding target"
        );
    }

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met.
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address beneficiary, uint256 weiAmount)
        internal
        view
    {
        require(beneficiary != address(0), "beneficiary is the zero address");
        require(weiAmount != 0, "weiAmount is 0");
        require(
            weiAmount >= minDeposit && weiAmount <= maxDeposit,
            "Amount exceeds min or max deposit allowed"
        );
        require(
            _totalJPEGRaised < fundingTarget,
            "Crowdsale Target reached"
        );
        require(
            weiRaised().add(weiAmount).mul(_rate) <= fundingTarget,
            "Crowdsale goal reached"
        );
        require(
            _totalJPEGRaised.add(weiAmount.mul(_rate)) <= fundingTarget,
            "Crowdsales goal reached"
        );
    }

    /**
     *
     * @dev Kickstart the ICO by setting the opning time and manually seting the closing time to a week after the opening time.
     */
    function startIco(uint256 _openingTime, uint256 _closingTime)
        external
        onlyAdmin
    {
        require(
            _openingTime >= block.timestamp && _openingTime < _closingTime,
            "start or end time invalid"
        );
        require(
            hasClosed(),
            "You can't restart ICO in the middle of sales period"
        );
        openingTime = _openingTime;
        closingTime = _closingTime;
    }

    /**
     * @dev Source of tokens. Override this method to modify the way in which the crowdsale ultimately gets and sends
     * its tokens.
     * @param beneficiary Address performing the token purchase
     * @param tokenAmount Number of tokens to be emitted
     */
    function _deliverTokens(address beneficiary, uint256 tokenAmount) internal {
        require(_token.transfer(beneficiary, tokenAmount));
    }

    /**
     * @dev Override to extend the way in which ether is converted to tokens.
     * @param weiAmount Value in wei to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _weiAmount
     */
    function getTokenClaimable(uint256 weiAmount)
        public
        view
        returns (uint256)
    {
        return weiAmount.mul(_rate);
    }

    function _forwardFunds() internal {
        Address.sendValue(payable(_wallet), msg.value);
    }

    /**
     * @dev Extend crowdsale.
     * @param newClosingTime Crowdsale closing time
     */
    function extendTime(uint256 newClosingTime) external onlyAdmin {
        require(!hasClosed(), "Ico already closed");
        // solhint-disable-next-line max-line-length

        closingTime = newClosingTime;
        emit JPEGVaultICOExtended(closingTime, newClosingTime);
    }

    function updateTotalRaised(uint256 totalWeiRaised, uint256 id)
        external
        onlyOracle
    {
        require(requests[id], "This request is not in my pending list.");
        _totalJPEGRaised = totalWeiRaised;
        delete requests[id];
        emit TotalRaisedUpdated(totalWeiRaised, id);
    }

    function setMinDeposit(uint256 _minDeposit) external onlyAdmin {
        require(_minDeposit != 0, "_minDeposit is zero");
        minDeposit = _minDeposit;
    }

    function setMaxDeposit(uint256 _maxDeposit) external onlyAdmin {
        require(_maxDeposit != 0, "_maxDeposit is zero");
        maxDeposit = _maxDeposit;
    }


    function setRate(uint256 rate) external onlyAdmin {
        require(rate != 0, "Rate is zero");
        _rate = rate;
    }
    
    function setAccessTokenMin(uint256 minAccessTokenBalance) external onlyAdmin {
        require(minAccessTokenBalance > 0, "value is zero");
        _minAccessTokenBalance = minAccessTokenBalance;
    }

    function requestTotalWeiRaised() internal {
        uint256 id = oracleInstance.requestTotalWeiRaised();
        requests[id] = true;
        emit NewTotalWeiRaisedRequest(id, oracleAddress);
    }

    function balanceOf(address _owner) public view returns (uint256) {
        return balances[_owner];
    }

    function isEarlyAccessPeriod() public view returns (bool) {
        if (isOpen()) return false;
        if(openingTime == 0 || closingTime == 0) return false;
        return openingTime.sub(block.timestamp) <= 1 days;
    }

    /**
     * @return the token being sold.
     */
    function getToken() public view returns (ERC20) {
        return _token;
    }

    /**
     * @return the address where funds are collected.
     */
    function getWallet() public view returns (address payable) {
        return _wallet;
    }

    /**
     * @return the number of token units a buyer gets per wei.
     */
    function getRate() public view returns (uint256) {
        return _rate;
    }

    /**
     * @return the amount of wei raised.
     */
    function weiRaised() public view returns (uint256) {
        return _weiRaised;
    }

    /**
     * @return the amount of jpeg wei raised.
     */
    function tokenRaised() public view returns (uint256) {
        return _weiRaised.mul(_rate);
    }

    function totalRaised() public view returns (uint256) {
        return _totalJPEGRaised;
    }

    function targetReached() public view returns (bool) {
        return totalRaised() == fundingTarget;
    }

    function isOpen() public view returns (bool) {
        return block.timestamp > openingTime && block.timestamp < closingTime;
    }

    function hasClosed() public view returns (bool) {
        return block.timestamp > closingTime;
    }
}
