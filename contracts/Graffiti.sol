// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV2Router {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

contract ProofOfGraffiti is ReentrancyGuard {
    // Token economics
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18; // 100M tokens
    uint256 public constant MINT_SUPPLY = 80_000_000 * 1e18;   // 80% for Graffiti
    uint256 public constant LP_SUPPLY = 20_000_000 * 1e18;     // 20% for LP
    uint256 public constant TOKENS_PER_PACK = 5_000 * 1e18;    // 5k tokens per pack

    // Tax (2% of BNB paid)
    address public constant TAX_ADDRESS = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
    uint256 public constant TAX_PERCENT = 200; // 2% in basis points

    // Max packs (80M / 5k = 16k)
    uint256 public constant MAX_PACKS = 16_000;

    // Price tiers (BNB per pack)
    uint256[8] public PRICE_TIERS = [
        0.001000 ether, // 0-10%
        0.001250 ether, // 10-20%
        0.001500 ether, // 20-30%
        0.001750 ether, // 30-40%
        0.002000 ether, // 40-50%
        0.002250 ether, // 50-60%
        0.002500 ether, // 60-70%
        0.002750 ether  // 70-80%
    ];

    // State variables
    address public tokenAddress;
    address public owner;
    uint256 public totalGraffitiPacks;
    uint256 public contractCreateTime;
    bool public launched;
    bool public graffitiEnded;
    bool public failed;

    // Failure data
    uint256 public failedTotalPacks;
    uint256 public failedTotalBNB;
    uint256 public failedRefundPerPack;

    // Anti-bot limits
    uint256 public constant MAX_PACKS_PER_TX = 80;      // <0.5% (80 packs)
    uint256 public constant MAX_PACKS_PER_BLOCK = 320; // 2% (320 packs)
    uint256 public lastGraffitiBlock;
    uint256 public currentBlockPacks;

    // User data
    struct UserInfo {
        uint256 totalPacks;       // Total Graffiti packs
        uint256 totalPaid;        // Total BNB paid
        uint256 soldPacks;        // Packs sold (40% unlockable)
        uint256 lockedPacks;      // Locked packs (60%)
        uint256 lastGraffitiBlock;// Last Graffiti block
        bool hasRefunded;         // Refund status
    }

    mapping(address => UserInfo) public users;
    address[] public graffitiParticipants;

    // Events
    event GraffitiCreated(address indexed creator, string name, string symbol, uint256 totalSupply);
    event GraffitiMinted(address indexed user, uint256 packs, uint256 pricePerPack, uint256 totalPaid, uint256 taxAmount);
    event TokensSold(address indexed user, uint256 packsSold, uint256 refundAmount);
    event Launched(uint256 tokenAmount, uint256 ethAmount, address lpToken);
    event Refunded(address indexed user, uint256 amount);
    event ProjectFailed(uint256 totalPacks, uint256 totalBNB, uint256 refundPerPack);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotLaunched() {
        require(!launched, "Already launched");
        _;
    }

    modifier whenGraffitiActive() {
        require(!graffitiEnded && !failed && !launched, "Graffiti ended");
        require(block.timestamp >= contractCreateTime, "Not started");
        require(block.timestamp <= contractCreateTime + 4 hours, "Graffiti expired");
        _;
    }

    modifier whenFailed() {
        require(failed, "Not failed");
        _;
    }

    constructor() {
        owner = msg.sender;
        contractCreateTime = block.timestamp;
    }

    // --- Core Functions ---

    /** @dev Participate in Graffiti (mint packs) */
    function graffiti(uint256 packCount) external payable nonReentrant whenNotLaunched whenGraffitiActive {
        require(tokenAddress != address(0), "Token not set");
        require(packCount > 0 && packCount <= 400, "Invalid pack count (1-400)");
        require(totalGraffitiPacks + packCount <= MAX_PACKS, "Exceeds max packs");

        _checkAntiBot(msg.sender, packCount);

        (, uint256 pricePerPack) = getCurrentTier();
        uint256 totalCost = packCount * pricePerPack;
        require(msg.value >= totalCost, "Insufficient BNB");

        // Calculate tax (2%)
        uint256 taxAmount = (totalCost * TAX_PERCENT) / 10_000;
        uint256 netCost = totalCost - taxAmount;

        // Transfer tax to TAX_ADDRESS
        if (taxAmount > 0) {
            payable(TAX_ADDRESS).transfer(taxAmount);
        }

        // Update user data
        UserInfo storage user = users[msg.sender];
        if (user.totalPacks == 0) {
            graffitiParticipants.push(msg.sender);
        }

        user.totalPaid += totalCost;
        user.totalPacks += packCount;
        user.lockedPacks += (packCount * 60) / 100; // 60% locked
        totalGraffitiPacks += packCount;

        // Refund excess BNB
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }

        emit GraffitiMinted(msg.sender, packCount, pricePerPack, totalCost, taxAmount);

        // Auto-launch if max packs reached
        if (totalGraffitiPacks >= MAX_PACKS) {
            _launch();
        }
    }

    /** @dev Sell 40% of unlockable packs (during Graffiti phase) */
    function sell() external nonReentrant whenNotLaunched whenGraffitiActive {
        UserInfo storage user = users[msg.sender];
        uint256 availablePacks = getSellablePacks(msg.sender);
        require(availablePacks > 0, "No packs to sell");

        (uint256 currentTier, uint256 currentPrice) = getCurrentTier();
        uint256 sellPrice = (currentTier == 0) ? currentPrice : PRICE_TIERS[currentTier - 1];
        uint256 refundAmount = availablePacks * sellPrice;

        require(address(this).balance >= refundAmount, "Insufficient contract balance");

        user.soldPacks += availablePacks;
        totalGraffitiPacks -= availablePacks; // Return packs to pool

        payable(msg.sender).transfer(refundAmount);
        emit TokensSold(msg.sender, availablePacks, refundAmount);
    }

    /** @dev Claim locked tokens (post-launch) */
    function claim() external nonReentrant {
        require(launched, "Not launched");
        UserInfo storage user = users[msg.sender];
        uint256 claimableTokens = user.lockedPacks * TOKENS_PER_PACK;
        require(claimableTokens > 0, "No tokens to claim");

        user.lockedPacks = 0;
        IERC20(tokenAddress).transfer(msg.sender, claimableTokens);
    }

    /** @dev Refund BNB if project failed */
    function refund() external nonReentrant whenFailed {
        UserInfo storage user = users[msg.sender];
        require(user.totalPacks > 0, "No packs to refund");
        require(!user.hasRefunded, "Already refunded");

        uint256 refundAmount = user.totalPacks * failedRefundPerPack;
        require(refundAmount > 0, "No refund available");
        require(address(this).balance >= refundAmount, "Insufficient balance");

        user.hasRefunded = true;
        payable(msg.sender).transfer(refundAmount);
        emit Refunded(msg.sender, refundAmount);
    }

    // --- Admin Functions ---

    /** @dev Launch the project (create LP pool) */
    function launch() external onlyOwner whenNotLaunched {
        _launch();
    }

    function _launch() internal {
        require(totalGraffitiPacks > 0, "No packs minted");
        uint256 ethBalance = address(this).balance;

        // Transfer LP tokens from owner to contract
        IERC20(tokenAddress).transferFrom(owner, address(this), LP_SUPPLY);

        // Approve and add liquidity
        IERC20(tokenAddress).approve(0x10ED43C718714eb63d5aA57B78B54704E256024E, LP_SUPPLY);
        IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E).addLiquidityETH{value: ethBalance}(
            tokenAddress,
            LP_SUPPLY,
            LP_SUPPLY,
            ethBalance,
            owner,
            block.timestamp + 1 hours
        );

        launched = true;
        graffitiEnded = true;
        emit Launched(LP_SUPPLY, ethBalance, address(this));
    }

    /** @dev Mark project as failed (if not launched in 4 hours) */
    function markAsFailed() external onlyOwner {
        require(!launched && !failed, "Already launched/failed");
        require(block.timestamp > contractCreateTime + 4 hours, "4 hours not passed");

        failed = true;
        graffitiEnded = true;
        failedTotalPacks = totalGraffitiPacks;
        failedTotalBNB = address(this).balance;
        failedRefundPerPack = (failedTotalPacks > 0) ? (failedTotalBNB / failedTotalPacks) : 0;

        emit ProjectFailed(failedTotalPacks, failedTotalBNB, failedRefundPerPack);
    }

    // --- Anti-Bot Checks ---

    function _checkAntiBot(address user, uint256 packCount) internal {
        require(packCount <= MAX_PACKS_PER_TX, "Exceeds max packs per TX");

        UserInfo storage userInfo = users[user];
        require(block.number != userInfo.lastGraffitiBlock, "One Graffiti per block");
        userInfo.lastGraffitiBlock = block.number;

        if (block.number != lastGraffitiBlock) {
            lastGraffitiBlock = block.number;
            currentBlockPacks = 0;
        }
        require(currentBlockPacks + packCount <= MAX_PACKS_PER_BLOCK, "Exceeds max packs per block");
        currentBlockPacks += packCount;
    }

    // --- View Functions ---

    /** @dev Get current price tier (0-7) and price per pack */
    function getCurrentTier() public view returns (uint256 tier, uint256 pricePerPack) {
        if (totalGraffitiPacks == 0) return (0, PRICE_TIERS[0]);

        uint256 progress = (totalGraffitiPacks * 100) / MAX_PACKS;
        if (progress < 10) return (0, PRICE_TIERS[0]);
        if (progress < 20) return (1, PRICE_TIERS[1]);
        if (progress < 30) return (2, PRICE_TIERS[2]);
        if (progress < 40) return (3, PRICE_TIERS[3]);
        if (progress < 50) return (4, PRICE_TIERS[4]);
        if (progress < 60) return (5, PRICE_TIERS[5]);
        if (progress < 70) return (6, PRICE_TIERS[6]);
        return (7, PRICE_TIERS[7]);
    }

    /** @dev Get sellable packs (40% of total, minus already sold) */
    function getSellablePacks(address user) public view returns (uint256) {
        UserInfo memory userInfo = users[user];
        uint256 totalSellable = (userInfo.totalPacks * 40) / 100;
        return (totalSellable > userInfo.soldPacks) ? (totalSellable - userInfo.soldPacks) : 0;
    }

    // --- Getters ---

    function getTotalPacks(address user) external view returns (uint256) {
        return users[user].totalPacks;
    }

    function getLockedPacks(address user) external view returns (uint256) {
        return users[user].lockedPacks;
    }

    function getContractCreateTime() external view returns (uint256) {
        return contractCreateTime;
    }

    function getProgress() external view returns (uint256 currentPacks, uint256 maxPacks, uint256 percentage) {
        return (totalGraffitiPacks, MAX_PACKS, (totalGraffitiPacks * 100) / MAX_PACKS);
    }

    function getCurrentPrice() external view returns (uint256) {
        (, uint256 price) = getCurrentTier();
        return price;
    }

    function getLaunchStatus() external view returns (bool isLaunched, bool isFailed) {
        return (launched, failed);
    }

    /** @dev Set token address (callable once by owner) */
    function setTokenAddress(address _tokenAddress) external onlyOwner {
        require(tokenAddress == address(0), "Token already set");
        require(_tokenAddress != address(0), "Invalid token address");
        tokenAddress = _tokenAddress;
        emit GraffitiCreated(msg.sender, "Graffiti Token", "GRAFFITI", TOTAL_SUPPLY);
    }

    receive() external payable {}
}
