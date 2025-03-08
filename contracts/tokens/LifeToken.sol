// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// 使用适配版本的OpenZeppelin合约
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract LifeToken is ERC20, Ownable {
    using SafeMath for uint256;

    // =============================
    // 常量声明
    // =============================
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 1e18;     // 50亿
    uint256 public constant INITIAL_SUPPLY = 2_000_000_000 * 1e18; // 初始20亿

    // =============================
    // 数据结构
    // =============================
    struct RebaseConfig {
        uint256 lastRebaseTime;   // 上次调整时间
        uint256 minRebaseInterval;// 最小间隔（秒）
        uint256 rebaseFactor;     // 调整系数（1e18为基础）
    }

    // =============================
    // 状态变量
    // =============================
    address public rebaser;       // Rebase操作员
    address public distributor;   // 初始分发地址
    bool public initialDistributionDone; // 初始分发状态
    
    RebaseConfig public rebaseConfig;     // Rebase配置
    mapping(address => bool) private _isExcludedFromRebase; // 排除地址列表
    mapping(address => uint256) private _baseBalances;      // 基础余额存储

    // =============================
    // 事件
    // =============================
    event Rebase(uint256 indexed epoch, uint256 oldFactor, uint256 newFactor);
    event RebaserUpdated(address indexed newRebaser);
    event DistributorUpdated(address indexed newDistributor);
    event ExcludedFromRebase(address indexed account, bool excluded);

    // =============================
    // 修饰符
    // =============================
    modifier onlyRebaser() {
        require(msg.sender == rebaser, "Caller is not the rebaser");
        _;
    }

    modifier onlyDistributor() {
        require(msg.sender == distributor, "Caller is not the distributor");
        _;
    }

    // =============================
    // 构造函数
    // =============================
    constructor(address initialOwner_)
        ERC20("ManageLife Token", "Life")
    {
        // 手动转移所有权
        _transferOwnership(initialOwner_);
        
        // 初始化权限地址
        rebaser = initialOwner_;
        distributor = initialOwner_;

        // 设置初始Rebase配置
        rebaseConfig = RebaseConfig({
            lastRebaseTime: block.timestamp,
            minRebaseInterval: 30 days,
            rebaseFactor: 1e18 // 1:1
        });

        // 铸造初始供应量到合约地址
        _baseBalances[address(this)] = INITIAL_SUPPLY;
        emit Transfer(address(0), address(this), INITIAL_SUPPLY);
    }

    // =============================
    // 主要功能函数
    // =============================
    
    /**
     * @dev 执行供应量调整
     * @param newFactor_ 新调整系数（1e18为基础，例如1.1e18表示+10%）
     */
    function rebase(uint256 newFactor_) external onlyRebaser {
        require(
            block.timestamp >= rebaseConfig.lastRebaseTime.add(rebaseConfig.minRebaseInterval),
            "Rebase interval not reached"
        );
        require(
            newFactor_ <= 1.5e18 && newFactor_ >= 0.5e18,
            "Factor out of allowed range (0.5x - 1.5x)"
        );

        uint256 oldFactor = rebaseConfig.rebaseFactor;
        rebaseConfig.rebaseFactor = newFactor_;
        rebaseConfig.lastRebaseTime = block.timestamp;

        emit Rebase(block.timestamp, oldFactor, newFactor_);
    }

    /**
     * @dev 初始代币分发
     * @param recipients_ 接收地址数组
     * @param amounts_ 分配数量数组（单位：百万枚）
     */
    function initialDistribution(
        address[] calldata recipients_,
        uint256[] calldata amounts_
    ) external onlyDistributor {
        require(!initialDistributionDone, "Distribution already completed");
        require(recipients_.length == amounts_.length, "Array length mismatch");

        uint256 totalDistributed;
        for (uint256 i = 0; i < recipients_.length; i++) {
            uint256 amount = amounts_[i].mul(1e6 * 1e18); // 转换为wei单位
            _transfer(address(this), recipients_[i], amount);
            totalDistributed = totalDistributed.add(amount);
        }

        require(totalDistributed == INITIAL_SUPPLY, "Invalid distribution total");
        initialDistributionDone = true;
    }

    // =============================
    // 视图函数
    // =============================
    
    /**
     * @dev 获取调整后的余额
     */
    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromRebase[account]) {
            return _baseBalances[account];
        }
        return _baseBalances[account].mul(rebaseConfig.rebaseFactor).div(1e18);
    }

    /**
     * @dev 获取调整后的总供应量
     */
    function totalSupply() public view override returns (uint256) {
        return super.totalSupply().mul(rebaseConfig.rebaseFactor).div(1e18);
    }

    // =============================
    // 内部函数
    // =============================
    
    /**
     * @dev 重写转账逻辑
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 senderBalance = balanceOf(sender);
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");

        // 转换为基础单位
        uint256 baseAmount = _isExcludedFromRebase[sender]
            ? amount
            : amount.mul(1e18).div(rebaseConfig.rebaseFactor);

        // 更新基础余额
        _baseBalances[sender] = _baseBalances[sender].sub(baseAmount);
        _baseBalances[recipient] = _baseBalances[recipient].add(baseAmount);

        emit Transfer(sender, recipient, amount);
    }

    // =============================
    // 管理函数
    // =============================
    
    function setRebaser(address newRebaser_) external onlyOwner {
        require(newRebaser_ != address(0), "Invalid address");
        rebaser = newRebaser_;
        emit RebaserUpdated(newRebaser_);
    }

    function setDistributor(address newDistributor_) external onlyOwner {
        require(!initialDistributionDone, "Distribution already completed");
        distributor = newDistributor_;
        emit DistributorUpdated(newDistributor_);
    }

    function excludeFromRebase(address account_, bool excluded_) external onlyOwner {
        _isExcludedFromRebase[account_] = excluded_;
        emit ExcludedFromRebase(account_, excluded_);
    }
}