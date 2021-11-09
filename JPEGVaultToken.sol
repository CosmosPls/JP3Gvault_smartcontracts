// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IUniswapV2Router02 {
    function addLiquidityETH(
      address token,
      uint amountTokenDesired,
      uint amountTokenMin,
      uint amountETHMin,
      address to,
      uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
      uint amountIn,
      uint amountOutMin,
      address[] calldata path,
      address to,
      uint deadline
    ) external;
}

contract JPEGvaultDAOToken is ERC20Snapshot, Ownable {
    using SafeMath for uint;
    using EnumerableSet for EnumerableSet.AddressSet;
    
    EnumerableSet.AddressSet private excludedRedistribution; // exclure de la redistribution
    EnumerableSet.AddressSet private excludedTax; // exclure du paiement des taxes

    IUniswapV2Router02 private m_UniswapV2Router;
    address private uniswapV2Pair;
    address private WETHAddr;
    
    address private devAddress;
    address private vaultAddress;
    address private redistributionContract;
    uint private devFees;
    uint private vaultFees;
    uint private liquidityFees;
    uint private minAmountForSwap;

    constructor(address _vault) ERC20("JPEGvaultDAO", "JPEG") {
        m_UniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        WETHAddr = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // mainnet change for ropsten if test
        
        devAddress = msg.sender;
        vaultAddress = _vault;
        
        excludedRedistribution.add(address(this));
        excludedRedistribution.add(msg.sender);
        excludedRedistribution.add(vaultAddress);
        excludedRedistribution.add(0xBae21D4247dd3818f720ab4210C095E84e980D96); // dxlock

        excludedTax.add(address(this));
        excludedTax.add(msg.sender);
        excludedTax.add(vaultAddress);
        excludedTax.add(0xBae21D4247dd3818f720ab4210C095E84e980D96); // dxlock

        devFees = 1;
        vaultFees = 7;
        liquidityFees = 2;
        minAmountForSwap = 100;
        _mint(msg.sender, 1000000000 * 10 ** 18);
    }
    
    receive() external payable {}
    
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        require(balanceOf(msg.sender) >= amount, "ERC20: transfer amount exceeds balance");
        
        if (excludedTax.contains(msg.sender)) {
            _transfer(msg.sender, recipient, amount);
            return true;
        } else {
            uint amountDev = amount.mul(devFees).div(100);
            uint amountVault = amount.mul(vaultFees).div(100);
            uint amountLiq = amount.mul(liquidityFees).div(100);
            uint newAmountTransfer = amount.sub(amountDev).sub(amountVault).sub(amountLiq);
            
            _transfer(msg.sender, devAddress, amountDev);
            _transfer(msg.sender, vaultAddress, amountVault);
            _transfer(msg.sender, address(this), amountLiq);
        
            swapAndLiquify();
            
            _transfer(msg.sender, recipient, newAmountTransfer);
            return true;
        }
    }
    
    function swapAndLiquify() private {
        uint balanceInToken = balanceOf(address(this));

        if (balanceInToken >= (minAmountForSwap * 1 ether) && uniswapV2Pair != address(0)) {
            uint amountLiqToken = balanceInToken.div(2);
            uint amountLiqSwapForEth = balanceInToken.sub(amountLiqToken);
            uint balanceInEth = address(this).balance;
            
            // swap token for ETH
            address[] memory _path = new address[](2);
            _path[0] = address(this);
            _path[1] = address(WETHAddr);
            _approve(address(this), address(m_UniswapV2Router), amountLiqSwapForEth);
            m_UniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountLiqSwapForEth,
                0,
                _path,
                address(this),
                block.timestamp
            );
            
            uint ethAmount = address(this).balance.sub(balanceInEth);
            
            // add liquidity with token and ETH
            _approve(address(this), address(m_UniswapV2Router), amountLiqToken);
            m_UniswapV2Router.addLiquidityETH{value: ethAmount}(
                address(this),
                amountLiqToken,
                0,
                0,
                owner(),
                block.timestamp
            );
        }
    }
    
    function createRedistribution() public returns (uint, uint) {
        require(msg.sender == redistributionContract, "Bad caller");

        uint newSnapshotId = _snapshot();

        return (newSnapshotId, calcSupplyHolders());
    }
    
    function calcSupplyHolders() internal view returns (uint) {
        uint balanceExcluded = 0;
        
        for (uint i = 0; i < excludedRedistribution.length(); i++)
            balanceExcluded += balanceOf(excludedRedistribution.at(i));
            
        return totalSupply() - balanceExcluded;
    }
    
    function setDevFees(uint _fees) public onlyOwner {
        devFees = _fees;
    }
    
    function setVaultFees(uint _fees) public onlyOwner {
        vaultFees = _fees;
    }
    
    function setLiquidityFees(uint _fees) public onlyOwner {
        liquidityFees = _fees;
    }
    
    function setMinAmountForSwap(uint _amount) public onlyOwner {
        minAmountForSwap = _amount;
    }
    
    function setWETHAddress(address _address) public onlyOwner {
        WETHAddr = _address;
    }
    
    function setDevAddress(address _address) public onlyOwner {
        devAddress = _address;
        excludedRedistribution.add(_address);
        excludedTax.add(_address);
    }
    
    function setVaultAddress(address _address) public onlyOwner {
        vaultAddress = _address;
        excludedRedistribution.add(_address);
        excludedTax.add(_address);
    }
    
    function setRedistributionContract(address _address) public onlyOwner {
        redistributionContract = _address;
        excludedRedistribution.add(_address);
        excludedTax.add(_address);
    }
    
    function setUniswapV2Pair(address _pair) public onlyOwner {
        uniswapV2Pair = _pair;
        excludedRedistribution.add(_pair);
    }
    
    function excludeTaxAddress(address _address) public onlyOwner {
        excludedTax.add(_address);
    }
    
    function excludedRedistributionAddress(address _address) public onlyOwner {
        excludedRedistribution.add(_address);
    }
    
    function removeTaxAddress(address _address) public onlyOwner {
        excludedTax.remove(_address);
    }
    
    function removeRedistributionAddress(address _address) public onlyOwner {
        excludedRedistribution.remove(_address);
    }
}
