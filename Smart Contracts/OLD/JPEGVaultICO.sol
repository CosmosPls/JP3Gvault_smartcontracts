// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";


contract JPEGVaultICO is ReentrancyGuard {
    using SafeMath for uint256;
    
     /* ICO parameters */
    bool public isFinalized;
    uint256 public minDeposit;
    uint256 public maxDeposit;
    uint256 public fundingTarget;
    uint public openingTime;
    uint public closingTime;
    uint private constant _1ether = 1000000000000000000;
   
     /* storage */
    mapping(address => uint256) public balances;
    mapping(address => bool) public tokenClaimed;


    // The token being sold
    ERC20 private _token;

    // Address where funds are collected
    address payable private _wallet;

    uint256 private _rate;

    // Amount of wei raised
    uint256 private _weiRaised;

    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokensPurchased(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);
    event TokenClaimed(address indexed beneficiary, uint256 amount);
    event JPEGVaultICOExtended(uint256 closingTime, uint256 newClosingTime);

    address private _admin;
    
    /**
     * @param rate Number of token units a buyer gets per wei
     * @dev The rate is the conversion between wei and the smallest and indivisible
     * @param wallet Address where collected funds will be forwarded to
     * @param tokenAddress Address of the token being sold
     */
    constructor(uint256 rate, address payable wallet, address admin, address tokenAddress, uint256 _minDeposit, uint256 _maxDeposit, uint256 _target) {
        require(rate > 0, "Crowdsale: rate is 0");
        require(wallet != address(0), "JPEGVaultICO: wallet is the zero address");
        require(admin != address(0), "JPEGVaultICO: admin is the zero address");
        require(tokenAddress != address(0), "JPEGVaultICO: token is the zero address");
        require(_maxDeposit > _minDeposit, "Maximum deposit allowed is not greater than the minimum desposit.");
        require(_target > 0, "Invalid Funding target set.");
        
        _rate = rate;
        _wallet = wallet;
        _token = ERC20(tokenAddress);
        _admin = admin;
        maxDeposit = _maxDeposit;
        minDeposit = _minDeposit;
        fundingTarget = _target;
    }
    
    /* Modifiers */
    modifier onlyWhileOpen() {
        require(isOpen(), "Sales is not currently on!");
        _;
    }
    
     modifier onlyAdmin() {
        require(msg.sender == _admin, "Unauthorized sender");
        _;
    }
    
    /**
     * @dev fallback function ***DO NOT OVERRIDE***
     * Note that other contracts will transfer funds with a base gas stipend
     * of 2300, which is not enough to call buyTokens. Consider calling
     * buyTokens directly when purchasing tokens from a contract.
     */
    receive() external payable {
        buyTokens(msg.sender);
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * This function has a non-reentrancy guard, so it shouldn't be called by
     * another `nonReentrant` function.
     * @param beneficiary Recipient of the token purchase
     */
    function buyTokens(address beneficiary) public nonReentrant payable onlyWhileOpen {
        uint256 weiAmount = msg.value;
        _preValidatePurchase(beneficiary, weiAmount);

        uint256 tokens = _getTokenAmount(weiAmount);

        _weiRaised = _weiRaised.add(weiAmount);

        _forwardFunds();
        
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
        
        require(tokenClaimed[beneficiary] == false, "Token already claimed!!!");
        
        uint256 tokenAmount = _getTokenAmount(balances[beneficiary]);
        
        tokenClaimed[beneficiary] = true;
        
        balances[beneficiary] = 0;
        
        // transfer token to beneficiary
        _deliverTokens(beneficiary, tokenAmount);
        
        emit TokenClaimed(beneficiary, tokenAmount);
    }

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met.
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address beneficiary, uint256 weiAmount) internal {
        require(beneficiary != address(0), "beneficiary is the zero address");
        require(weiAmount != 0, "weiAmount is 0");
        require(weiAmount >= minDeposit && weiAmount <= maxDeposit, "Amount should be within 0.05 eth and 1 eth");
        require(weiRaised().add(weiAmount) <= fundingTarget, "Crowdsale goal reached");
        
        uint256 _existingbalance = balances[beneficiary];
        uint256 _newBalance = _existingbalance.add(weiAmount);
        require(_newBalance <= maxDeposit, "Maximum deposit exceeded!!!");
        
        balances[beneficiary] = _newBalance;
    }
    
    /**
     * 
     * @dev Kickstart the ICO by setting the opning time and manually seting the closing time to a week after the opening time.
     */ 
     function startIco( uint256 _openingTime) external onlyAdmin {
        require(_openingTime >= block.timestamp, "JPEGVaultICO: opening time is before current block timestamp");
        require(openingTime == 0 || hasClosed(), "You can't restart ICO in the middle of sales period");
        openingTime = _openingTime;
        closingTime = openingTime + 1 weeks;
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
    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        uint256 total = weiAmount.mul(_rate);
        return total;
    }
    
    function _forwardFunds() internal {
        _wallet.transfer(msg.value);
    }
     /**
     * @dev Extend crowdsale.
     * @param newClosingTime Crowdsale closing time
     */
    function extendTime(uint256 newClosingTime) external onlyAdmin {
        require(!hasClosed(), "JPEGVaultICO: already closed");
        // solhint-disable-next-line max-line-length
        require(newClosingTime > closingTime, "JPEGVaultICO: new closing time is before current closing time");

        emit JPEGVaultICOExtended(closingTime, newClosingTime);
        closingTime = newClosingTime;
    }
    
    function balanceOf(address _owner) public view returns(uint256) {
        return balances[_owner];
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
    
    function targetReached() public view returns(bool) {
        return weiRaised() == fundingTarget;
    }

    
    function isOpen() public view returns(bool) {
        return block.timestamp > openingTime && block.timestamp < closingTime;
    }
    
    function hasClosed() public view returns(bool) {
        return block.timestamp > closingTime;
    }

}