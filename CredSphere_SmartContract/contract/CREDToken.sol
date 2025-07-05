// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/governance/utils/Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";


contract CREDToken is ERC20, ERC20Burnable, Votes, ERC20Permit, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    /// @notice Token economics constants
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**18;
    uint256 public constant JOB_POSTING_FEE = 10 * 10**18;
    uint256 public constant DAO_STAKE_AMOUNT = 1000 * 10**18;

    /// @notice Reward constants
    uint256 public constant PROFILE_CREATION_REWARD = 10 * 10**18;
    uint256 public constant CREDENTIAL_MINT_REWARD = 5 * 10**18;
    uint256 public constant JOB_APPLICATION_REWARD = 1 * 10**18;
    uint256 public constant RATING_REWARD = 1 * 10**18;
    uint256 public constant DAO_VOTE_REWARD = 1 * 10**18;
    uint256 public constant CREDENTIAL_VERIFICATION_REWARD = 20 * 10**18;
    uint256 public constant JOB_COMPLETION_REWARD = 50 * 10**18;

    address public daoAddress;
    mapping(string => uint256) public rewardAmounts;
    mapping(address => mapping(string => uint256)) public actionCounts;
    mapping(address => mapping(string => uint256)) public actionTimestamps;
    mapping(address => uint256) public stakedBalance;
    uint256 public totalStaked;
    uint256 public stakingAPY = 500; // 5% annual yield
    mapping(address => uint256) public stakingRewards;
    mapping(address => uint256) public lastRewardClaim;
    uint256 public inflationRate = 200; // 2% initial inflation
    uint256 public lastInflationAdjustment;
    uint256 public constant INFLATION_ADJUSTMENT_PERIOD = 365 days;

    struct FeeAmounts {
        uint256 jobFee;
        uint256 daoStake;
    }

    event RewardPaid(address indexed recipient, string action, uint256 amount);
    event RewardAmountUpdated(string action, uint256 oldAmount, uint256 newAmount);
    event FeePaid(address indexed from, uint256 amount, string purpose);
    event TokensStaked(address indexed user, uint256 amount);
    event TokensUnstaked(address indexed user, uint256 amount);
    event StakingRewardsClaimed(address indexed user, uint256 amount);
    event InflationAdjusted(uint256 newRate);

    error ExceedsMaxSupply();
    error InsufficientBalance();
    error NotAuthorized();
    error InvalidRewardType();
    error RewardAlreadyClaimed();

    /// @notice Constructor initializes the token with roles and initial supply
    constructor() ERC20("CredSphere Token", "CRED") ERC20Permit("CredSphere Token") Votes() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);
        super._mint(msg.sender, INITIAL_SUPPLY);
        _initializeRewards();
        lastInflationAdjustment = block.timestamp;
    }

    /// @notice Initializes reward amounts for actions
    function _initializeRewards() internal {
        rewardAmounts["profile_creation"] = PROFILE_CREATION_REWARD;
        rewardAmounts["credential_mint"] = CREDENTIAL_MINT_REWARD;
        rewardAmounts["job_application"] = JOB_APPLICATION_REWARD;
        rewardAmounts["rating"] = RATING_REWARD;
        rewardAmounts["dao_vote"] = DAO_VOTE_REWARD;
        rewardAmounts["credential_verification"] = CREDENTIAL_VERIFICATION_REWARD;
        rewardAmounts["job_completion"] = JOB_COMPLETION_REWARD;
    }

    /// @notice Mints new tokens to an address
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) whenNotPaused {
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        super._mint(to, amount);
    }

    /// @notice Burns tokens from the caller
    /// @param amount Amount to burn
    function burn(uint256 amount) public override {
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        super._burn(msg.sender, amount);
    }

    /// @notice Burns tokens from a specific account
    /// @param account Account to burn from
    /// @param amount Amount to burn
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        _spendAllowance(account, msg.sender, amount);
        super._burn(account, amount);
    }

    /// @notice Pays a reward for an action
    /// @param to Recipient address
    /// @param action Action type (e.g., "dao_vote")
    function payReward(address to, string memory action) external onlyRole(REWARD_MANAGER_ROLE) nonReentrant {
        if (bytes(action).length == 0) revert InvalidRewardType();
        uint256 rewardAmount = rewardAmounts[action];
        if (rewardAmount == 0) revert InvalidRewardType();

        // Rate limiting: 1 reward per action per day
        string memory rateLimitKey = string(abi.encodePacked(action, "_", Strings.toString(block.timestamp / 86400)));
        if (actionTimestamps[to][rateLimitKey] != 0) revert RewardAlreadyClaimed();

        // Diminishing returns
        uint256 totalActionCount = actionCounts[to][action];
        if (totalActionCount > 10) {
            rewardAmount = (rewardAmount * 50) / 100; // 50% reduction
        } else if (totalActionCount > 5) {
            rewardAmount = (rewardAmount * 75) / 100; // 25% reduction
        }

        if (totalSupply() + rewardAmount > MAX_SUPPLY) revert ExceedsMaxSupply();

        actionCounts[to][action]++;
        actionTimestamps[to][rateLimitKey] = block.timestamp;
        super._mint(to, rewardAmount);
        emit RewardPaid(to, action, rewardAmount);
    }

    /// @notice Updates the reward amount for an action
    /// @param action Action type
    /// @param newAmount New reward amount
    function updateRewardAmount(string memory action, uint256 newAmount) external onlyRole(REWARD_MANAGER_ROLE) {
        uint256 oldAmount = rewardAmounts[action];
        rewardAmounts[action] = newAmount;
        emit RewardAmountUpdated(action, oldAmount, newAmount);
    }

    /// @notice Gets the reward amount for an action
    /// @param action Action type
    /// @return Reward amount
    function getRewardAmount(string memory action) external view returns (uint256) {
        return rewardAmounts[action];
    }

    /// @notice Pays a fee for an action
    /// @param amount Fee amount
    /// @param purpose Fee purpose
    function payFee(uint256 amount, string memory purpose) external nonReentrant {
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        super._burn(msg.sender, amount);
        emit FeePaid(msg.sender, amount, purpose);
    }

    /// @notice Gets fee amounts for platform actions
    /// @return FeeAmounts struct with job and DAO stake fees
 function getFeeAmounts() external pure returns (FeeAmounts memory) {
    FeeAmounts memory fee = FeeAmounts({jobFee: JOB_POSTING_FEE, daoStake: DAO_STAKE_AMOUNT});
    return fee;
}

    /// @notice Stakes tokens for rewards
    /// @param amount Amount to stake
    function stakeTokens(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InsufficientBalance();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _claimStakingRewards(msg.sender);
        _transfer(msg.sender, address(this), amount);
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        emit TokensStaked(msg.sender, amount);
    }

    /// @notice Unstakes tokens
    /// @param amount Amount to unstake
    function unstakeTokens(uint256 amount) external nonReentrant {
        if (amount == 0 || stakedBalance[msg.sender] < amount) revert InsufficientBalance();
        _claimStakingRewards(msg.sender);
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        _transfer(address(this), msg.sender, amount);
        emit TokensUnstaked(msg.sender, amount);
    }

    /// @notice Claims staking rewards
    function claimStakingRewards() external nonReentrant {
        _claimStakingRewards(msg.sender);
    }

    /// @notice Internal function to claim staking rewards
    /// @param user User claiming rewards
    function _claimStakingRewards(address user) internal {
        uint256 staked = stakedBalance[user];
        if (staked == 0) return;
        uint256 timeSinceLastClaim = block.timestamp - lastRewardClaim[user];
        if (timeSinceLastClaim == 0) return;
        uint256 rewards = (staked * stakingAPY * timeSinceLastClaim) / (365 days * 10000);
        if (rewards > 0 && totalSupply() + rewards <= MAX_SUPPLY) {
            super._mint(user, rewards);
            stakingRewards[user] += rewards;
            lastRewardClaim[user] = block.timestamp;
            emit StakingRewardsClaimed(user, rewards);
        }
    }

    /// @notice Adjusts the inflation rate
    function adjustInflationRate() external {
        if (block.timestamp < lastInflationAdjustment + INFLATION_ADJUSTMENT_PERIOD) revert NotAuthorized();
        inflationRate = (inflationRate * 90) / 100; // 10% reduction
        lastInflationAdjustment = block.timestamp;
        emit InflationAdjusted(inflationRate);
    }

    /// @notice Gets the voting power of an account
    /// @param account Account address
    /// @return Voting power
    function getVotingPower(address account) external view returns (uint256) {
        return getVotes(account) + stakedBalance[account];
    }

    /// @notice Sets the DAO address
    /// @param _daoAddress DAO contract address
    function setDaoAddress(address _daoAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        daoAddress = _daoAddress;
    }

    /// @notice Pauses the contract
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Overrides nonces to resolve conflict between ERC20Permit and Nonces
    /// @param owner Address to check nonces for
    /// @return Current nonce
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @notice Returns the voting units for an account
    /// @param account Address to check
    /// @return Voting units
    function _getVotingUnits(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }

    /// @notice Delegates voting power to a delegatee
    /// @param account Account delegating
    /// @param delegatee Delegatee address
    function _delegate(address account, address delegatee) internal override {
        super._delegate(account, delegatee);
    }

    /// @notice Transfers voting units between accounts
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount of voting units
    function _transferVotingUnits(address from, address to, uint256 amount) internal override {
        super._transferVotingUnits(from, to, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}