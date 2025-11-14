// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IUniswapV2Router {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract ProofOfGraffiti is ReentrancyGuard {
    using SafeMath for uint256;
    
    // 代币经济参数
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 10**18; // 100M
    uint256 public constant MINT_SUPPLY = 80_000_000 * 10**18;   // 80% for Graffiti
    uint256 public constant LP_SUPPLY = 20_000_000 * 10**18;     // 20% for LP
    uint256 public constant TOKENS_PER_PACK = 5_000 * 10**18;    // 每张pack 5k代币
    
    // 最大张数计算
    uint256 public constant MAX_PACKS = 16_000; // 80,000,000 / 5,000 = 16,000张
    
    // 价格阶梯 (BNB per pack)
    uint256[8] public PRICE_TIERS = [
        0.001000 ether,    // 10%内: 每张0.001 BNB
        0.001250 ether,    // 20%内: 每张0.00125 BNB  
        0.001500 ether,    // 30%内: 每张0.0015 BNB
        0.001750 ether,    // 40%内: 每张0.00175 BNB
        0.002000 ether,    // 50%内: 每张0.002 BNB
        0.002250 ether,    // 60%内: 每张0.00225 BNB
        0.002500 ether,    // 70%内: 每张0.0025 BNB
        0.002750 ether     // 80%内: 每张0.00275 BNB
    ];
    
    // 状态变量
    address public tokenAddress;
    address public owner;
    uint256 public totalGraffitiPacks; // 总Graffiti张数
    uint256 public contractCreateTime;
    bool public launched;
    bool public graffitiEnded;
    bool public failed;
    
    // 失败时记录的数据
    uint256 public failedTotalPacks;
    uint256 public failedTotalBNB;
    uint256 public failedRefundPerPack;
    
    // 反狙击参数
    uint256 public constant MAX_PACKS_PER_TX = 80; // <0.5% (80张)
    uint256 public constant MAX_PACKS_PER_BLOCK = 320; // 2% (320张)
    uint256 public lastGraffitiBlock;
    uint256 public currentBlockPacks;
    
    // 用户数据结构
    struct UserInfo {
        uint256 totalPacks;           // 总Graffiti张数
        uint256 totalPaid;            // 总支付金额
        uint256 soldPacks;            // 已卖出张数
        uint256 lockedPacks;          // 锁定张数 (60%)
        uint256 lastGraffitiBlock;    // 最后Graffiti区块
        bool hasRefunded;             // 是否已退款
    }
    
    mapping(address => UserInfo) public users;
    address[] public graffitiParticipants;
    
    // 事件
    event GraffitiCreated(address indexed creator, string name, string symbol, uint256 totalSupply);
    event GraffitiMinted(address indexed user, uint256 packs, uint256 price, uint256 totalPaid);
    event TokensSold(address indexed user, uint256 packsSold, uint256 refundAmount);
    event Launched(uint256 tokenAmount, uint256 ethAmount, address lpToken);
    event Refunded(address indexed user, uint256 amount);
    event ProjectFailed(uint256 totalPacks, uint256 totalBNB, uint256 refundPerPack);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier whenNotLaunched() {
        require(!launched, "Already launched");
        _;
    }
    
    modifier whenGraffitiActive() {
        require(!graffitiEnded && !failed && !launched, "Graffiti period ended");
        require(block.timestamp >= contractCreateTime, "Not started");
        require(block.timestamp <= contractCreateTime + 4 hours, "Graffiti period expired");
        _;
    }
    
    modifier whenFailed() {
        require(failed, "Project not failed");
        _;
    }
    
    constructor() {
        owner = msg.sender;
        contractCreateTime = block.timestamp;
    }
    
    // 🎨 Graffiti函数 - 用户参与涂鸦
    function graffiti(uint256 packCount) external payable nonReentrant whenNotLaunched whenGraffitiActive {
        require(tokenAddress != address(0), "Token not created");
        require(packCount > 0 && packCount <= 400, "Invalid pack count 1-400");
        
        // 反狙击检查
        _checkAntiBot(msg.sender, packCount);
        
        require(totalGraffitiPacks + packCount <= MAX_PACKS, "Exceeds graffiti supply");
        
        // 获取当前价格档位
        (uint256 currentTier, uint256 pricePerPack) = getCurrentTier();
        uint256 totalCost = packCount * pricePerPack;
        
        require(msg.value >= totalCost, "Insufficient BNB");
        
        // 更新用户信息
        UserInfo storage user = users[msg.sender];
        if (user.totalPacks == 0) {
            graffitiParticipants.push(msg.sender);
        }
        
        user.totalPaid += totalCost;
        user.totalPacks += packCount;
        
        // 计算锁定和可卖出部分 (60%锁定，40%可卖出)
        uint256 lockedPacks = packCount * 60 / 100;
        user.lockedPacks += lockedPacks;
        
        // 更新全局状态
        totalGraffitiPacks += packCount;
        
        // 退还多余BNB
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
        
        emit GraffitiMinted(msg.sender, packCount, pricePerPack, totalCost);
        
        // 检查是否打满自动发射
        if (totalGraffitiPacks >= MAX_PACKS) {
            _launch();
        }
    }
    
    // 💰 卖出40%代币 (不传入参数，自动卖出可卖出的40%)
    function sell() external nonReentrant whenNotLaunched whenGraffitiActive {
        UserInfo storage user = users[msg.sender];
        uint256 availablePacks = getSellablePacks(msg.sender);
        require(availablePacks > 0, "No packs to sell");
        
        // 获取当前档位和上一档价格
        (uint256 currentTier, uint256 currentPrice) = getCurrentTier();
        uint256 sellPrice;
        
        if (currentTier == 0) {
            // 第一档使用当前价格
            sellPrice = currentPrice;
        } else {
            // 使用上一档价格
            sellPrice = PRICE_TIERS[currentTier - 1];
        }
        
        uint256 refundAmount = availablePacks * sellPrice;
        
        // 检查合约余额
        require(address(this).balance >= refundAmount, "Insufficient contract balance");
        
        // 更新状态
        user.soldPacks += availablePacks;
        
        // 卖出的张数回到Graffiti池
        totalGraffitiPacks -= availablePacks;
        
        // 支付退款
        payable(msg.sender).transfer(refundAmount);
        
        emit TokensSold(msg.sender, availablePacks, refundAmount);
    }
    
    // 🎯 提取代币（发射后）- 按张数计算claim的代币数
    function claim() external nonReentrant {
        require(launched, "Not launched yet");
        
        UserInfo storage user = users[msg.sender];
        uint256 claimableTokens = user.lockedPacks * TOKENS_PER_PACK;
        require(claimableTokens > 0, "No tokens to claim");
        
        user.lockedPacks = 0;
        
        IERC20(tokenAddress).transfer(msg.sender, claimableTokens);
    }
    
    // 🔄 失败退款机制
    function refund() external nonReentrant whenFailed {
        UserInfo storage user = users[msg.sender];
        require(user.totalPacks > 0, "No packs to refund");
        require(!user.hasRefunded, "Already refunded");
        
        uint256 refundAmount = user.totalPacks * failedRefundPerPack;
        require(refundAmount > 0, "No refund available");
        require(address(this).balance >= refundAmount, "Insufficient contract balance");
        
        user.hasRefunded = true;
        payable(msg.sender).transfer(refundAmount);
        
        emit Refunded(msg.sender, refundAmount);
    }
    
    // 🚀 发射函数
    function launch() external onlyOwner whenNotLaunched {
        _launch();
    }
    
    function _launch() internal {
        require(totalGraffitiPacks > 0, "No packs minted");
        
        uint256 ethBalance = address(this).balance;
        
        // 转移代币到合约
        IERC20(tokenAddress).transferFrom(owner, address(this), LP_SUPPLY);
        
        // 创建PancakeSwap LP池
        IERC20(tokenAddress).approve(0x10ED43C718714eb63d5aA57B78B54704E256024E, LP_SUPPLY);
        
        (uint amountToken, uint amountETH, uint liquidity) = IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E)
            .addLiquidityETH{value: ethBalance}(
                tokenAddress,
                LP_SUPPLY,
                LP_SUPPLY,
                ethBalance,
                owner,
                block.timestamp + 1 hours
            );
        
        launched = true;
        graffitiEnded = true;
        
        emit Launched(amountToken, amountETH, address(this));
    }
    
    // ⏰ 标记项目失败（4小时未发射）
    function markAsFailed() external onlyOwner {
        require(!launched && !failed, "Already launched or failed");
        require(block.timestamp > contractCreateTime + 4 hours, "4 hours not passed");
        
        failed = true;
        graffitiEnded = true;
        
        // 记录失败时数据
        failedTotalPacks = totalGraffitiPacks;
        failedTotalBNB = address(this).balance;
        
        // 计算每张pack的退款金额
        if (failedTotalPacks > 0 && failedTotalBNB > 0) {
            failedRefundPerPack = failedTotalBNB / failedTotalPacks;
        }
        
        emit ProjectFailed(failedTotalPacks, failedTotalBNB, failedRefundPerPack);
    }
    
    // 🔒 反狙击检查
    function _checkAntiBot(address user, uint256 packCount) internal {
        // 单TX限制
        require(packCount <= MAX_PACKS_PER_TX, "Exceeds max packs per TX");
        
        // 单地址每区块限制
        UserInfo storage userInfo = users[user];
        require(block.number != userInfo.lastGraffitiBlock, "One graffiti per block per address");
        userInfo.lastGraffitiBlock = block.number;
        
        // 单区块总限制
        if (block.number != lastGraffitiBlock) {
            lastGraffitiBlock = block.number;
            currentBlockPacks = 0;
        }
        require(currentBlockPacks + packCount <= MAX_PACKS_PER_BLOCK, "Exceeds max packs per block");
        currentBlockPacks += packCount;
    }
    
    // 📊 读取函数
    
    // 获取当前档位和价格
    function getCurrentTier() public view returns (uint256 tier, uint256 pricePerPack) {
        if (totalGraffitiPacks == 0) return (0, PRICE_TIERS[0]);
        
        uint256 progressPercentage = totalGraffitiPacks * 100 / MAX_PACKS;
        
        if (progressPercentage < 10) return (0, PRICE_TIERS[0]);
        else if (progressPercentage < 20) return (1, PRICE_TIERS[1]);
        else if (progressPercentage < 30) return (2, PRICE_TIERS[2]);
        else if (progressPercentage < 40) return (3, PRICE_TIERS[3]);
        else if (progressPercentage < 50) return (4, PRICE_TIERS[4]);
        else if (progressPercentage < 60) return (5, PRICE_TIERS[5]);
        else if (progressPercentage < 70) return (6, PRICE_TIERS[6]);
        else return (7, PRICE_TIERS[7]);
    }
    
    // 📈 获取地址总Graffiti张数
    function getTotalPacks(address user) external view returns (uint256) {
        return users[user].totalPacks;
    }
    
    // 🔐 获取地址锁定张数
    function getLockedPacks(address user) external view returns (uint256) {
        return users[user].lockedPacks;
    }
    
    // 🎯 获取地址未锁定张数（可卖出）
    function getSellablePacks(address user) public view returns (uint256) {
        UserInfo memory userInfo = users[user];
        uint256 totalSellable = (userInfo.totalPacks * 40 / 100);
        if (totalSellable > userInfo.soldPacks) {
            return totalSellable - userInfo.soldPacks;
        }
        return 0;
    }
    
    // ⏱️ 获取合约创建时间
    function getContractCreateTime() external view returns (uint256) {
        return contractCreateTime;
    }
    
    // 📊 获取当前进度（按张数计算）
    function getProgress() external view returns (uint256 currentPacks, uint256 maxPacks, uint256 percentage) {
        return (totalGraffitiPacks, MAX_PACKS, totalGraffitiPacks * 100 / MAX_PACKS);
    }
    
    // 💰 获取当前阶段价格
    function getCurrentPrice() external view returns (uint256 pricePerPack) {
        (, uint256 price) = getCurrentTier();
        return price;
    }
    
    // 🚀 获取发射状态
    function getLaunchStatus() external view returns (bool isLaunched, bool isFailed) {
        return (launched, failed);
    }
    
    // 📝 设置代币地址
    function setTokenAddress(address _tokenAddress) external onlyOwner {
        require(tokenAddress == address(0), "Token address already set");
        tokenAddress = _tokenAddress;
        
        emit GraffitiCreated(msg.sender, "Graffiti Token", "GRAFFITI", TOTAL_SUPPLY);
    }
    
    // 💰 接收BNB
    receive() external payable {}
}
