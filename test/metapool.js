const { expect } = require('chai');
const bn = require('bignumber.js');

bn.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 })

// returns the sqrt price as a 64x96
function encodePriceSqrt(reserve1, reserve0) {
  return new bn(reserve1.toString())
    .div(reserve0.toString())
    .sqrt()
    .multipliedBy(new bn(2).pow(96))
    .integerValue(3)
    .toString()
}

function position(address, lowerTick, upperTick) {
  return ethers.utils.solidityKeccak256(
    ['address', 'int24', 'int24'],
    [address, lowerTick, upperTick],
  );
}

describe('MetaPools', function() {
  let uniswapFactory;
  let uniswapPool;
  let token0;
  let token1;
  let metaPoolFactory;
  const nonExistantToken = '0x1111111111111111111111111111111111111111';
  let user0;
  let user1;
  let swapTest;

  before(async function() {
    ([user0, user1] = await ethers.getSigners());
    
    const SwapTest = await ethers.getContractFactory('SwapTest');
    swapTest = await SwapTest.deploy();
  })

  beforeEach(async function() {
    const UniswapV3Factory = await ethers.getContractFactory('UniswapV3Factory');
    const _uniswapFactory = await UniswapV3Factory.deploy();
    uniswapFactory = await ethers.getContractAt('IUniswapV3Factory', _uniswapFactory.address);

    const MetaPoolFactory = await ethers.getContractFactory('MetaPoolFactory');
    metaPoolFactory = await MetaPoolFactory.deploy(uniswapFactory.address);

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token0 = await MockERC20.deploy();
    token1 = await MockERC20.deploy();

    await token0.approve(swapTest.address, ethers.utils.parseEther('10000000000000'));
    await token1.approve(swapTest.address, ethers.utils.parseEther('10000000000000'));

    // Sort token0 & token1 so it follows the same order as Uniswap & the MetaPoolFactory
    if (ethers.BigNumber.from(token0.address).gt(ethers.BigNumber.from(token1.address))) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await uniswapFactory.createPool(token0.address, token1.address, '3000');
    const uniswapPoolAddress = await uniswapFactory.getPool(token0.address, token1.address, '3000');
    uniswapPool = await ethers.getContractAt('IUniswapV3Pool', uniswapPoolAddress);
    await uniswapPool.initialize(encodePriceSqrt('1', '1'));
  });

  describe('MetaPoolFactory', async function() {
    it('Should create a metapool for an existing Uniswap V3 pool', async function() {
      const tx = await metaPoolFactory.createPool(token0.address, token1.address);
      const receipt = await tx.wait();

      expect(receipt.events.length).to.equal(1);
      expect(receipt.events[0].event).to.equal('PoolCreated');
      expect(receipt.events[0].args[0]).to.equal(token0.address);
      expect(receipt.events[0].args[1]).to.equal(token1.address);

      const calculatedAddress = await metaPoolFactory.calculatePoolAddress(token0.address, token1.address);
      expect(calculatedAddress).to.equal(receipt.events[0].args[2]);

      const metaPool = await ethers.getContractAt('MetaPool', calculatedAddress);
      expect(await metaPool.currentPool()).to.equal(uniswapPool.address);
      expect(await metaPool.token0()).to.equal(token0.address);
      expect(await metaPool.token1()).to.equal(token1.address);
      expect(await metaPool.currentLowerTick()).to.equal(-887220);
      expect(await metaPool.currentUpperTick()).to.equal(887220);
      expect(await metaPool.currentUniswapFee()).to.equal(3000);
    });

    it('Should fail to create a metapool if there is no Uniswap 0.3% pool', async function() {
      await expect(
        metaPoolFactory.createPool(token0.address, nonExistantToken)
      ).to.be.reverted;
    });

    it('Should fail to create the same pool twice', async function() {
      await metaPoolFactory.createPool(token0.address, token1.address);
      await expect(
        metaPoolFactory.createPool(token0.address, token1.address)
      ).to.be.reverted;
    });
  });

  describe('MetaPool', function() {
    let metaPool;

    beforeEach(async function() {
      await metaPoolFactory.createPool(token0.address, token1.address);
      const calculatedAddress = await metaPoolFactory.calculatePoolAddress(token0.address, token1.address);
      metaPool = await ethers.getContractAt('MetaPool', calculatedAddress);

      await token0.approve(calculatedAddress, ethers.utils.parseEther('1000000'));
      await token1.approve(calculatedAddress, ethers.utils.parseEther('1000000'));
    });

    describe('deposits', function() {
      it('Should deposit funds into a metapool', async function() {
        await metaPool.mint('1000');

        expect(await token0.balanceOf(uniswapPool.address)).to.equal('1000');
        expect(await token1.balanceOf(uniswapPool.address)).to.equal('1000');
        const [liquidity] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
        expect(liquidity).to.equal('1000');
        expect(await metaPool.totalSupply()).to.equal('1000');
        expect(await metaPool.balanceOf(await user0.getAddress())).to.equal('1000');

        await metaPool.mint('500');

        expect(await token0.balanceOf(uniswapPool.address)).to.equal('1500');
        expect(await token1.balanceOf(uniswapPool.address)).to.equal('1500');
        const [liquidity2] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
        expect(liquidity2).to.equal('1500');
        expect(await metaPool.totalSupply()).to.equal('1500');
        expect(await metaPool.balanceOf(await user0.getAddress())).to.equal('1500');
      });
    });

    describe('adjustParams', function() {
      it('should fail if not called by owner', async function() {
        await expect(
          metaPool.connect(user1).adjustParams(-443610, 443610, '3000')
        ).to.be.reverted;
      });
    });

    describe('with liquidity depositted', function() {
      beforeEach(async function() {
        await metaPool.mint('10000');
      });

      describe('withdrawal', function() {
        it('should burn LP tokens and withdraw funds', async function() {
          await metaPool.burn('6000');

          expect(await token0.balanceOf(uniswapPool.address)).to.equal('4001');
          expect(await token1.balanceOf(uniswapPool.address)).to.equal('4001');
          const [liquidity2] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
          expect(liquidity2).to.equal('4000');
          expect(await metaPool.totalSupply()).to.equal('4000');
          expect(await metaPool.balanceOf(await user0.getAddress())).to.equal('4000');
        });
      });

      describe('after lots of balanced trading', function() {
        beforeEach(async function() {
          await swapTest.washTrade(uniswapPool.address, '1000', 100, 2);
          await swapTest.washTrade(uniswapPool.address, '1000', 100, 2);
        });

        describe('rebalance', function() {
          it('should redeposit fees with a rebalance', async function() {
            await metaPool.rebalance();

            expect(await token0.balanceOf(uniswapPool.address)).to.equal('10200');
            expect(await token1.balanceOf(uniswapPool.address)).to.equal('10200');
            const [liquidity2] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
            expect(liquidity2).to.equal('10099');
          });
        });

        describe('adjust params', function() {
          it('should change the ticks and rebalance', async function() {
            await metaPool.adjustParams(-443580, 443580, '3000');

            await metaPool.rebalance();

            const [liquidityOld] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
            expect(liquidityOld).to.equal('0');

            const [liquidityNew] = await uniswapPool.positions(position(metaPool.address, -443580, 443580));
            expect(liquidityNew).to.equal('10098');
          });

          it('should change the fee & ticks and rebalance', async function() {
            await uniswapFactory.createPool(token0.address, token1.address, 500);
            const uniswapPoolAddress = await uniswapFactory.getPool(token0.address, token1.address, 500);
            const pool2 = await ethers.getContractAt('IUniswapV3Pool', uniswapPoolAddress);
            await pool2.initialize(encodePriceSqrt('1', '1'));

            await metaPool.adjustParams(-443580, 443580, 500);

            await metaPool.rebalance();

            const [liquidityOld] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
            expect(liquidityOld).to.equal('0');

            const [liquidityNew] = await pool2.positions(position(metaPool.address, -443580, 443580));
            expect(liquidityNew).to.equal('10098');
          });
        });
      });

      describe('after lots of unbalanced trading', function() {
        beforeEach(async function() {
          await swapTest.washTrade(uniswapPool.address, '1000', 100, 4);
          await swapTest.washTrade(uniswapPool.address, '1000', 100, 4);
        });

        describe('rebalance', function() {
          it('should redeposit fees with a rebalance', async function() {
            await metaPool.rebalance();

            expect(await token0.balanceOf(uniswapPool.address)).to.equal('10299');
            expect(await token1.balanceOf(uniswapPool.address)).to.equal('10100');
            expect(await token0.balanceOf(metaPool.address)).to.equal('1');
            expect(await token1.balanceOf(metaPool.address)).to.equal('0');
            const [liquidity2] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
            expect(liquidity2).to.equal('10097');
          });
        });

        describe('adjust params', function() {
          it('should change the ticks and rebalance', async function() {
            await metaPool.adjustParams(-443580, 443580, '3000');

            await metaPool.rebalance();

            const [liquidityOld] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
            expect(liquidityOld).to.equal('0');

            const [liquidityNew] = await uniswapPool.positions(position(metaPool.address, -443580, 443580));
            expect(liquidityNew).to.equal('10096');
          });

          it('should change the fee & ticks and rebalance', async function() {
            await uniswapFactory.createPool(token0.address, token1.address, 500);
            const uniswapPoolAddress = await uniswapFactory.getPool(token0.address, token1.address, 500);
            const pool2 = await ethers.getContractAt('IUniswapV3Pool', uniswapPoolAddress);
            await pool2.initialize(encodePriceSqrt('1', '1'));

            await metaPool.adjustParams(-443580, 443580, 500);

            await metaPool.rebalance();

            const [liquidityOld] = await uniswapPool.positions(position(metaPool.address, -887220, 887220));
            expect(liquidityOld).to.equal('0');

            const [liquidityNew] = await pool2.positions(position(metaPool.address, -443580, 443580));
            expect(liquidityNew).to.equal('10096');
          });
        });
      });
    });
  });
});
