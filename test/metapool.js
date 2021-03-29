const { expect } = require('chai');

describe('MetaPools', function() {
  let uniswapFactory;
  let uniswapPool;
  let token0;
  let token1;
  let metaPoolFactory;
  const nonExistantToken = '0x1111111111111111111111111111111111111111';

  beforeEach(async function() {
    const UniswapV3Factory = await ethers.getContractFactory('UniswapV3Factory');
    const _uniswapFactory = await UniswapV3Factory.deploy();
    uniswapFactory = await ethers.getContractAt('IUniswapV3Factory', _uniswapFactory.address);

    const MetaPoolFactory = await ethers.getContractFactory('MetaPoolFactory');
    metaPoolFactory = await MetaPoolFactory.deploy(uniswapFactory.address);

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token0 = await MockERC20.deploy();
    token1 = await MockERC20.deploy();

    // Sort token0 & token1 so it follows the same order as Uniswap & the MetaPoolFactory
    if (ethers.BigNumber.from(token0.address).gt(ethers.BigNumber.from(token1.address))) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await uniswapFactory.createPool(token0.address, token1.address, '3000');
    const uniswapPoolAddress = await uniswapFactory.getPool(token0.address, token1.address, '3000');
    uniswapPool = await ethers.getContractAt('IUniswapV3Pool', uniswapPoolAddress);
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
    });
  });
});
