// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import '@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol';

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract JPEGv5 is ERC20Upgradeable, OwnableUpgradeable {

    mapping(address => bool) private excludedTax;

    IUniswapV2Router02 public dexRouter;
    address private dexPair;
    address private wETHAddr;

    address private growthAddress;
    address private treasuryAddress;

    // @notice autoLiquidityFees is a fraction of the tax for the liquidity
    uint8 private autoLiquidityFees;

    // Autoselling ratio between 0 and 100
    uint8 private autoSellingRatio;

    uint216 private minAmountForSwap;

    uint8 public purchaseTax;
    uint8 public sellTax;
    uint8 public walletTax;

    address private bridgeAddress;

    uint private autoSellStack;

    uint16 public minimumBlockDelay;
    mapping(address => uint256) private lastTransfer;

    struct TaxDiscount {
      uint64 buyDiscount;
      uint64 sellDiscount;
      uint64 walletDiscount;
      uint64 expirationDate;
    }
    mapping(address => TaxDiscount) public userToTaxDiscount;

    uint64 constant MAXDISCOUNT = 10000;

    address public taxAgent;

    event UpdatedAgent(address sender, address agent);
    event MinimumBlockDelayUpdated(uint16 blockCount);
    event PurchaseTaxUpdated(uint8 tax);
    event SellTaxUpdated(uint8 tax);
    event WalletTaxUpdated(uint8 tax);
    event ExcludedFromTax(address beneficiary);
    event RemovedTaxExemption(address beneficiary);
    event TreasuryAddressUpdated(address treasure);
    event BridgeAddressUpdated(address bridge);
    event AutoLiquidityFeesUpdated(uint8 _fees);
    event MinAmountForSwap(uint216 _amount);
    event DexPairUpdated(address _pair);
    event AutoSellingRatioUpdated(uint8 ratio);
    event DexRouterUpdated(address newAddress);

    function initialize(
        address _growthAddress,
        address _treasuryAddress,
        address _router) external initializer {
        __Ownable_init();
        __ERC20_init("JP3G", "JP3G");

        dexRouter = IUniswapV2Router02(_router);
        wETHAddr = dexRouter.WETH();

        growthAddress = _growthAddress;
        _transferOwnership(_growthAddress);

        treasuryAddress = _treasuryAddress;

        excludedTax[treasuryAddress] = true;
        excludedTax[address(this)] = true;
        excludedTax[growthAddress] = true;

        purchaseTax = 10;
        sellTax = 10;
        walletTax = 10;

        minAmountForSwap = 1_000;

        _mint(growthAddress, 1_000_000_000 * 10 ** 18);
    }

    receive() external payable {}

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (!excludedTax[sender] &&
            !excludedTax[recipient]) {

            if (recipient == dexPair) {
                uint64 discount = userToTaxDiscount[sender].sellDiscount;
                if (userToTaxDiscount[sender].expirationDate > 0 &&
                    block.timestamp > userToTaxDiscount[sender].expirationDate) {
                    discount = 0;
                }
                amount = applyTaxes(sender, amount, sellTax, discount);
                checkLastTransfer(sender);
            }
            else if (sender == dexPair) {
                uint64 discount = userToTaxDiscount[recipient].buyDiscount;
                if (userToTaxDiscount[recipient].expirationDate > 0 &&
                    block.timestamp > userToTaxDiscount[recipient].expirationDate) {
                    discount = 0;
                }
                amount = applyTaxes(sender, amount, purchaseTax, discount);
                checkLastTransfer(recipient);
            }
            else {
                uint64 discount = userToTaxDiscount[sender].walletDiscount;
                if (userToTaxDiscount[sender].expirationDate > 0 &&
                    block.timestamp > userToTaxDiscount[sender].expirationDate) {
                    discount = 0;
                }
                amount = applyTaxes(sender, amount, walletTax, discount);
            }
        }
        super._transfer(sender, recipient, amount);
    }

    function checkLastTransfer(address trader) internal {
        if (minimumBlockDelay > 0) {
            require ((block.number - lastTransfer[trader]) >= minimumBlockDelay,
                      "Transfer too close from previous one");
            lastTransfer[trader] = block.number;
        }
    }

    // @dev : be careful to block size limit.
    // @dev : tax is expressed with 2 significant digits. 2000 = 20%
    // @dev : max discount = 10000 (100%)
    function setTaxDiscount(address[] memory _beneficiaries, TaxDiscount[] memory _discounts) external {
      require(_beneficiaries.length == _discounts.length, "array size error");
      require(msg.sender == taxAgent, "Only Tax Agent");
      for(uint i = 0; i < _beneficiaries.length; i++) {
        require(_discounts[i].buyDiscount <= MAXDISCOUNT &&
                _discounts[i].sellDiscount <= MAXDISCOUNT &&
                _discounts[i].walletDiscount <= MAXDISCOUNT, "MAXDISCOUNT");
        userToTaxDiscount[_beneficiaries[i]] = _discounts[i];
      }
    }

    function setTaxAgent(address _newAgent) external onlyOwner {
      taxAgent = _newAgent;
      emit UpdatedAgent(msg.sender, _newAgent);
    }

    function applyTaxes(address sender, uint amount, uint8 tax, uint64 taxDiscount) internal returns (uint newAmountTransfer) {
        if (taxDiscount == MAXDISCOUNT) return amount;

        uint amountTax = (amount * tax * (MAXDISCOUNT - taxDiscount)) ;

        // Calculate the liquidity portion
        uint amountAutoLiquidity = (amountTax * autoLiquidityFees / 100);
        amountTax -= amountAutoLiquidity;

      // Cheaper without "no division by 0" check
        unchecked {
            amountTax /= 100 * MAXDISCOUNT;
            amountAutoLiquidity /= 100 * MAXDISCOUNT;
        }

        newAmountTransfer = amount
            - amountTax
            - amountAutoLiquidity;

        // Apply autoselling ratio
        uint autoSell = amountTax * autoSellingRatio;

        // Cheaper without "no division by 0" check
        unchecked {
            autoSell /= 100;
        }

        // Transfer the remaining tokens to wallets
        super._transfer(sender, treasuryAddress, amountTax - autoSell);

        // Transfer all autoselling + autoLP to the contract
        super._transfer(sender, address(this), autoSell
                                               + amountAutoLiquidity);

        uint tokenBalance = balanceOf(address(this));

        // Only swap if it's worth it
        if (tokenBalance >= (minAmountForSwap * 1 ether)
            && dexPair != address(0)
            && dexPair != msg.sender) {

            swapAndLiquify(tokenBalance,
                            autoSell);
        } else {
            // Stack tokens to be swapped for autoselling
            autoSellStack = autoSellStack + autoSell;
        }
    }

    function swapAndLiquify(uint tokenBalance,
                            uint autoSell) internal {
        uint finalAutoSell = autoSellStack + autoSell;

        uint amountToLiquifiy = tokenBalance - finalAutoSell;

        // Stack tokens for autoliquidity pool
        uint tokensToBeSwappedForLP;
        unchecked {
            tokensToBeSwappedForLP = amountToLiquifiy / 2;
        }
        uint tokensForLP = amountToLiquifiy - tokensToBeSwappedForLP;

        uint totalToSwap = finalAutoSell + tokensToBeSwappedForLP;

        // Swap all in one call
        uint balance = address(this).balance;
        swapTokens(totalToSwap);
        uint totalswaped = address(this).balance - balance;

        // Redistribute according to weigth
        uint autosell = totalswaped * finalAutoSell / totalToSwap;

        AddressUpgradeable.sendValue(payable(treasuryAddress), autosell);

        uint availableForLP = totalswaped - autosell;
        addLiquidity(tokensForLP, availableForLP);

        autoSellStack = 0;
    }

    function addLiquidity(uint tokenAmount, uint ethAmount) internal {
        if (tokenAmount >0) {
            // add liquidity with token and ETH
            _approve(address(this), address(dexRouter), tokenAmount);
            dexRouter.addLiquidityETH{value: ethAmount}(
                address(this),
                tokenAmount,
                0,
                0,
                owner(),
                block.timestamp
            );
        }
    }

    function swapTokens(uint256 amount) private {
        address[] memory _path = new address[](2);
        _path[0] = address(this);
        _path[1] = address(wETHAddr);

        _approve(address(this), address(dexRouter), amount);

        dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            _path,
            address(this),
            block.timestamp
        );
    }

    function setMinimumBlockDelay(uint16 blockCount) external onlyOwner {
        minimumBlockDelay = blockCount;
        emit MinimumBlockDelayUpdated(blockCount);
    }

    function setPurchaseTax(uint8 _tax) external onlyOwner {
        purchaseTax = _tax;
        emit PurchaseTaxUpdated(_tax);
    }

    function setSellTax(uint8 _tax) external onlyOwner {
        sellTax = _tax;
        emit SellTaxUpdated(_tax);
    }

    function setWalletTax(uint8 _tax) external onlyOwner {
        walletTax = _tax;
        emit WalletTaxUpdated(_tax);
    }

    function setTreasuryAddress(address _address) external onlyOwner {
        treasuryAddress = _address;
        _excludeFromTax(_address);
        emit TreasuryAddressUpdated(_address);
    }

    function setBridgeAddress(address _address) external onlyOwner {
        bridgeAddress = _address;
        _excludeFromTax(_address);
        emit BridgeAddressUpdated(_address);
    }

    function excludeFromTax(address _address) external onlyOwner {
        _excludeFromTax(_address);
    }

    function _excludeFromTax(address _address) internal {
        excludedTax[_address] = true;
        emit ExcludedFromTax(_address);
    }

    function removeTaxExemption(address _address) external onlyOwner {
        require(_address != address(this), "Not authorized to remove the contract from tax");
        excludedTax[_address] = false;
        emit RemovedTaxExemption(_address);
    }

    // Bridging feature
    function mint(address to, uint256 amount) external {
        require(msg.sender == bridgeAddress, "Only bridge can mint");
        _mint(to, amount);
    }

    function burn(address to, uint256 amount) external {
        require(msg.sender == bridgeAddress, "Only bridge can mint");
        _burn(to, amount);
    }

    function setDexRouter(address newAddress) external onlyOwner {
        dexRouter = IUniswapV2Router02(newAddress);
        wETHAddr = dexRouter.WETH();
        emit DexRouterUpdated(newAddress);
    }

    // Liquidity settings

    function setAutoLiquidityFees(uint8 _fees) external onlyOwner {
        require(_fees <= 100, "Too high");
        autoLiquidityFees = _fees;
        emit AutoLiquidityFeesUpdated(_fees);
    }

    function setMinAmountForSwap(uint216 _amount) external onlyOwner {
        minAmountForSwap = _amount;
        emit MinAmountForSwap(_amount);
    }

    function setDexPair(address _pair) external onlyOwner {
        dexPair = _pair;
        emit DexPairUpdated(_pair);
    }

    function setAutoSellingRatio(uint8 ratio) external onlyOwner{
        require(autoSellingRatio <= 100, "autoSellingRatio should be lower than 100");
        autoSellingRatio = ratio;
        emit AutoSellingRatioUpdated(ratio);
    }
}
