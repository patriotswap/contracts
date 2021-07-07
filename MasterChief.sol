// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./PatriotToken.sol";
import "./TheWall.sol";

// MasterChef is the master of Patriot. He can make Patriot and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once PATRIOT is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChief is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of PATRIOTs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accPatriotPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accPatriotPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. PATRIOTs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that PATRIOTs distribution occurs.
        uint256 accPatriotPerShare;   // Accumulated PATRIOTs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The PATRIOT TOKEN!
    PatriotToken public patriot;
    TheWall public wall;
    // Dev address.
    address public devaddr;
    // PATRIOT tokens created per block.
    uint256 public patriotPerBlock;
    // Bonus muliplier for early patriot makers.
    uint256 public PATRIOT_MULTIPLIER = 2;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when PATRIOT mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 patriotPerBlock);
    event UpdateMultiplier(address indexed user, uint256 newMultiplier);

    constructor(
        PatriotToken _patriot,
        TheWall _wall,
        address _devaddr,
        address _feeAddress,
        uint256 _patriotPerBlock,
        uint256 _startBlock
    ) public {
        patriot = _patriot;
        wall = _wall;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        patriotPerBlock = _patriotPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accPatriotPerShare : 0,
        depositFeeBP : _depositFeeBP
        }));
    }

    function isPatriot(address _address) public view returns (bool) {
      return wall.balanceOf(_address) > 0;
    }

    // Update the given pool's PATRIOT allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to, address _user) public view returns (uint256) {
      bool isPatriotStatus = isPatriot(_user);
      if (isPatriotStatus) {
          return _to.sub(_from).mul(PATRIOT_MULTIPLIER);
      }
          return _to.sub(_from);
    }

    // View function to see pending PATRIOTs on frontend.
    function pendingPatriot(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPatriotPerShare = pool.accPatriotPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number, _user);
            uint256 patriotReward = multiplier.mul(patriotPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accPatriotPerShare = accPatriotPerShare.add(patriotReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accPatriotPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number, msg.sender);
        uint256 patriotReward = multiplier.mul(patriotPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        patriot.mint(devaddr, patriotReward.div(10));
        patriot.mint(address(this), patriotReward);
        pool.accPatriotPerShare = pool.accPatriotPerShare.add(patriotReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for PATRIOT allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accPatriotPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safePatriotTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accPatriotPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accPatriotPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safePatriotTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPatriotPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe patriot transfer function, just in case if rounding error causes pool to not have enough PATRIOTs.
    function safePatriotTransfer(address _to, uint256 _amount) internal {
        uint256 patriotBal = patriot.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > patriotBal) {
            transferSuccess = patriot.transfer(_to, patriotBal);
        } else {
            transferSuccess = patriot.transfer(_to, _amount);
        }
        require(transferSuccess, "safePatriotTransfer: transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function updateEmissionRate(uint256 _patriotPerBlock) public onlyOwner {
        massUpdatePools();
        patriotPerBlock = _patriotPerBlock;
        emit UpdateEmissionRate(msg.sender, _patriotPerBlock);
    }

    function updateMultiplier(uint256 newMultiplier) public onlyOwner {
        require(newMultiplier >= 1, "new Multiplier must be greater than 1X");
        require(newMultiplier <= 5, "new Multiplier cannot be greater than 5X to prevent unnecessary inflation");
        PATRIOT_MULTIPLIER = newMultiplier;
        emit UpdateMultiplier(msg.sender, newMultiplier);
    }


}
