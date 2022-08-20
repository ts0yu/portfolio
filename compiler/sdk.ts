import ethers, { BigNumber } from 'ethers'
import { parseEther } from 'ethers/lib/utils'
import * as instructions from './instructions'

export default class HyperSDK {
  public signer: ethers.Signer
  public getHyperFactory: (signer: ethers.Signer) => Promise<ethers.ContractFactory>
  public getForwarderFactory: (signer: ethers.Signer) => Promise<ethers.ContractFactory>
  public instance: ethers.Contract | undefined
  public forwarder: ethers.Contract | undefined

  constructor(signer, getHyperFactory, getForwarderFactory) {
    this.signer = signer
    this.getHyperFactory = getHyperFactory
    this.getForwarderFactory = getForwarderFactory
    this.instance = undefined
    this.forwarder = undefined
  }

  async deploy(...args) {
    let factory = await this.getHyperFactory(this.signer)
    const instance = await factory.deploy(...args)
    this.instance = instance

    factory = await this.getForwarderFactory(this.signer)
    const forwarder = await factory.deploy()
    this.forwarder = forwarder

    return this.instance
  }

  createPool(
    asset: string,
    quote: string,
    strike: BigNumber,
    sigma: number,
    maturity: number,
    fee: number,
    price: BigNumber
  ): Promise<any> {
    let { bytes: pairData } = instructions.encodeCreatePair(asset, quote)
    let { bytes: curveData } = instructions.encodeCreateCurve(BigNumber.from(strike), sigma, maturity, fee)
    let { bytes: poolData } = instructions.encodeCreatePool(1, 1, price)
    let { hex: data } = instructions.encodeJumpInstruction([pairData, curveData, poolData])
    return this.forward(data)

    //return this.signer.sendTransaction({ to: this.instance.address, value: BigInt(0), data })
  }

  async addLiquidity(poolId: number, loTick: number, hiTick: number, amount: BigNumber) {
    let { hex: data } = instructions.encodeAddLiquidity(false, poolId, loTick, hiTick, amount)
    return this.forward(data)
  }

  async removeLiquidity(useMax: boolean, poolId: number, loTick: number, hiTick: number, amount: BigNumber) {
    let { hex: data } = instructions.encodeRemoveLiquidity(useMax, poolId, loTick, hiTick, amount)
    return this.forward(data)
  }

  async swapAssetToQuote(useMax: boolean, poolId: number, amount: BigNumber, limit: BigNumber, direction: 0 | 1) {
    let { hex: data } = instructions.encodeSwapExactTokens(useMax, poolId, amount, limit, direction)
    return this.forward(data)
  }

  async swapQuoteToAsset(useMax: boolean, poolId: number, amount: BigNumber, limit: BigNumber, direction: 0 | 1) {
    let { hex: data } = instructions.encodeSwapExactTokens(useMax, poolId, amount, limit, direction)
    return this.forward(data)
  }

  private forward(data: string) {
    if (typeof this.instance == 'undefined' || typeof this.forwarder == 'undefined')
      throw new Error('Hyper not deployed, call deploy().')

    return this.forwarder.pass(this.instance.address, data)
  }
}
