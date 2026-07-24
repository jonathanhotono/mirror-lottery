import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, type Address } from "viem";

const { viem, networkHelpers } = await network.create({
  network: "hardhatMainnet",
  chainType: "l1",
});

const USDC = 10n ** 6n;
const KEY_HASH = `0x${"11".repeat(32)}` as const;
const SOURCE_HASH = `0x${"22".repeat(32)}` as const;
const REASON_HASH = `0x${"33".repeat(32)}` as const;

const DRAW_STATE = {
  OPEN: 1,
  AWAITING_VRF: 2,
  MIRROR_PROPOSED: 3,
  RESULT_READY: 4,
  REGISTRATION: 5,
  SETTLED: 6,
  CLOSED: 7,
  CANCELLED: 8,
} as const;

type DrawView = {
  state: number;
  closesAt: number;
  registrationDeadline: number;
  claimDeadline: number;
  requestId: bigint;
  randomWord: bigint;
  winningNumbers: bigint;
  winnerCount: readonly number[];
};

function asDraw(value: unknown) {
  return value as DrawView;
}

function asBigInt(value: unknown) {
  return value as bigint;
}

function packTicket(numbers: number[]) {
  return numbers.reduce(
    (packed, value, index) =>
      packed | (BigInt(value) << BigInt(index * 8)),
    0n,
  );
}

function packResult(numbers: number[], bonus: number) {
  return packTicket(numbers) | (BigInt(bonus) << 48n);
}

async function deployFixture() {
  const wallets = await viem.getWalletClients();
  const [
    admin,
    manager,
    publisher,
    verifier,
    guardian,
    treasurer,
    treasury,
    alice,
    bob,
    captain,
  ] = wallets;

  const usdc = await viem.deployContract("MockUSDC");
  const coordinator = await viem.deployContract("MockVrfCoordinator");
  const lottery = await viem.deployContract("MirrorLottery", [
    usdc.address,
    {
      coordinator: coordinator.address,
      subscriptionId: 1n,
      keyHash: KEY_HASH,
      callbackGasLimit: 500_000,
      requestConfirmations: 3,
    },
    {
      mirrorChallengePeriod: 60,
      resultTimeout: 600,
      registrationPeriod: 120,
      claimPeriod: 240,
    },
    200,
    3_600,
    {
      admin: admin.account.address,
      drawManager: manager.account.address,
      resultPublisher: publisher.account.address,
      resultVerifier: verifier.account.address,
      guardian: guardian.account.address,
      treasurer: treasurer.account.address,
      treasury: treasury.account.address,
    },
  ]);

  for (const wallet of [alice, bob, captain]) {
    await usdc.write.mint([
      wallet.account.address,
      10_000n * USDC,
    ]);
    await usdc.write.approve(
      [lottery.address, 10_000n * USDC],
      { account: wallet.account },
    );
  }

  return {
    admin,
    manager,
    publisher,
    verifier,
    guardian,
    treasurer,
    treasury,
    alice,
    bob,
    captain,
    usdc,
    coordinator,
    lottery,
  };
}

type Fixture = Awaited<ReturnType<typeof deployFixture>>;

async function createDraw(
  fixture: Fixture,
  mode: 0 | 1,
  options: {
    ticketPrice?: bigint;
    rolloverAmount?: bigint;
  } = {},
) {
  const now = await networkHelpers.time.latest();
  await fixture.lottery.write.createDraw(
    [
      {
        mode,
        opensAt: BigInt(now),
        closesAt: BigInt(now + 100),
        ticketPrice: options.ticketPrice ?? 2n * USDC,
        maxNumber: 49,
        tierBps: [1_000, 1_500, 2_000, 2_500, 3_000],
        rolloverAmount: options.rolloverAmount ?? 0n,
      },
    ],
    { account: fixture.manager.account },
  );
  return asBigInt(await fixture.lottery.read.drawCount());
}

async function advancePastClose(fixture: Fixture, drawId: bigint) {
  const draw = asDraw(await fixture.lottery.read.getDraw([drawId]));
  await networkHelpers.time.increaseTo(Number(draw.closesAt) + 1);
}

async function publishMirrorResult(
  fixture: Fixture,
  drawId: bigint,
  result: bigint,
) {
  await advancePastClose(fixture, drawId);
  await fixture.lottery.write.proposeMirrorResult(
    [drawId, result, SOURCE_HASH],
    { account: fixture.publisher.account },
  );
  await fixture.lottery.write.confirmMirrorResult(
    [drawId, result, SOURCE_HASH],
    { account: fixture.verifier.account },
  );
  await networkHelpers.time.increase(61);
  await fixture.lottery.write.finalizeMirrorResult([drawId]);
}

describe("MirrorLottery", async function () {
  it("uses role separation and rejects malformed tickets", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const drawId = await createDraw(fixture, 0);

    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.createDraw([
        {
          mode: 0,
          opensAt: 1n,
          closesAt: 2n,
          ticketPrice: 2n * USDC,
          maxNumber: 49,
          tierBps: [1_000, 1_500, 2_000, 2_500, 3_000],
          rolloverAmount: 0n,
        },
      ], { account: fixture.alice.account }),
      fixture.lottery,
      "AccessControlUnauthorizedAccount",
    );

    const duplicateNumbers = packTicket([1, 2, 3, 3, 5, 6]);
    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.buyTickets(
        [drawId, [duplicateNumbers]],
        { account: fixture.alice.account },
      ),
      fixture.lottery,
      "InvalidNumbers",
    );

    const tooMany = Array.from(
      { length: 51 },
      () => packTicket([1, 2, 3, 4, 5, 6]),
    );
    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.buyTickets(
        [drawId, tooMany],
        { account: fixture.alice.account },
      ),
      fixture.lottery,
      "BatchTooLarge",
    );
  });

  it("rejects fee-on-transfer payment tokens", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const feeToken = await viem.deployContract("FeeOnTransferUSDC");
    const feeLottery = await viem.deployContract("MirrorLottery", [
      feeToken.address,
      {
        coordinator: fixture.coordinator.address,
        subscriptionId: 1n,
        keyHash: KEY_HASH,
        callbackGasLimit: 500_000,
        requestConfirmations: 3,
      },
      {
        mirrorChallengePeriod: 60,
        resultTimeout: 600,
        registrationPeriod: 120,
        claimPeriod: 240,
      },
      200,
      3_600,
      {
        admin: fixture.admin.account.address,
        drawManager: fixture.manager.account.address,
        resultPublisher: fixture.publisher.account.address,
        resultVerifier: fixture.verifier.account.address,
        guardian: fixture.guardian.account.address,
        treasurer: fixture.treasurer.account.address,
        treasury: fixture.treasury.account.address,
      },
    ]);

    await feeToken.write.mint([
      fixture.alice.account.address,
      100n * USDC,
    ]);
    await feeToken.write.approve(
      [feeLottery.address, 100n * USDC],
      { account: fixture.alice.account },
    );

    const now = await networkHelpers.time.latest();
    await feeLottery.write.createDraw(
      [
        {
          mode: 0,
          opensAt: BigInt(now),
          closesAt: BigInt(now + 100),
          ticketPrice: 2n * USDC,
          maxNumber: 49,
          tierBps: [1_000, 1_500, 2_000, 2_500, 3_000],
          rolloverAmount: 0n,
        },
      ],
      { account: fixture.manager.account },
    );

    await viem.assertions.revertWithCustomError(
      feeLottery.write.buyTickets(
        [1n, [packTicket([1, 2, 3, 4, 5, 6])]],
        { account: fixture.alice.account },
      ),
      feeLottery,
      "TransferAmountMismatch",
    );
    assert.equal(await feeLottery.read.ticketCount(), 0n);
  });

  it("stores VRF output in a minimal callback and finalizes permissionlessly", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const drawId = await createDraw(fixture, 0);

    await fixture.lottery.write.buyTickets(
      [drawId, [packTicket([1, 2, 3, 4, 5, 6])]],
      { account: fixture.alice.account },
    );
    await advancePastClose(fixture, drawId);

    await fixture.lottery.write.requestRandomness(
      [drawId],
      { account: fixture.manager.account },
    );
    let draw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    assert.equal(draw.state, DRAW_STATE.AWAITING_VRF);

    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.rawFulfillRandomWords(
        [draw.requestId, [123n]],
        { account: fixture.alice.account },
      ),
      fixture.lottery,
      "OnlyCoordinator",
    );

    await fixture.coordinator.write.fulfill([
      draw.requestId,
      42_424_242n,
    ]);
    draw = asDraw(await fixture.lottery.read.getDraw([drawId]));
    assert.equal(draw.state, DRAW_STATE.RESULT_READY);
    assert.equal(draw.randomWord, 42_424_242n);

    await networkHelpers.time.increaseTo(
      Number(draw.closesAt) + 601,
    );
    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.cancelExpiredDraw([drawId]),
      fixture.lottery,
      "InvalidState",
    );

    await fixture.lottery.write.finalizeVrfResult(
      [drawId],
      { account: fixture.bob.account },
    );
    draw = asDraw(await fixture.lottery.read.getDraw([drawId]));
    assert.equal(draw.state, DRAW_STATE.REGISTRATION);

    const [mainNumbers, bonus] =
      (await fixture.lottery.read.unpackNumbers([
        draw.winningNumbers,
      ])) as readonly [readonly number[], number];
    assert.equal(new Set(mainNumbers).size, 6);
    assert.equal(mainNumbers.includes(bonus), false);
    assert.equal(
      mainNumbers.every((value) => value >= 1 && value <= 49),
      true,
    );
  });

  it("requires two-party mirror attestation and honors the challenge window", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const drawId = await createDraw(fixture, 1);
    const result = packResult([1, 2, 3, 4, 5, 6], 7);

    await advancePastClose(fixture, drawId);
    await fixture.lottery.write.proposeMirrorResult(
      [drawId, result, SOURCE_HASH],
      { account: fixture.publisher.account },
    );
    let draw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    assert.equal(draw.state, DRAW_STATE.MIRROR_PROPOSED);

    const verifierRole =
      await fixture.lottery.read.RESULT_VERIFIER_ROLE();
    await fixture.lottery.write.grantRole(
      [verifierRole, fixture.publisher.account.address],
      { account: fixture.admin.account },
    );
    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.confirmMirrorResult(
        [drawId, result, SOURCE_HASH],
        { account: fixture.publisher.account },
      ),
      fixture.lottery,
      "SameAttestor",
    );

    await fixture.lottery.write.confirmMirrorResult(
      [drawId, result, SOURCE_HASH],
      { account: fixture.verifier.account },
    );
    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.finalizeMirrorResult([drawId]),
      fixture.lottery,
      "ChallengePeriodActive",
    );

    await fixture.lottery.write.challengeMirrorResult(
      [drawId, REASON_HASH],
      { account: fixture.guardian.account },
    );
    draw = asDraw(await fixture.lottery.read.getDraw([drawId]));
    assert.equal(draw.state, DRAW_STATE.OPEN);

    await fixture.lottery.write.proposeMirrorResult(
      [drawId, result, SOURCE_HASH],
      { account: fixture.publisher.account },
    );
    await fixture.lottery.write.confirmMirrorResult(
      [drawId, result, SOURCE_HASH],
      { account: fixture.verifier.account },
    );
    await networkHelpers.time.increase(61);
    await fixture.lottery.write.finalizeMirrorResult([drawId]);
    draw = asDraw(await fixture.lottery.read.getDraw([drawId]));
    assert.equal(draw.state, DRAW_STATE.REGISTRATION);
  });

  it("settles fixed tiers, allows claims while paused, and only withdraws accrued fees", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const drawId = await createDraw(fixture, 1);
    const result = packResult([1, 2, 3, 4, 5, 6], 7);
    const tickets = [
      packTicket([1, 2, 3, 4, 5, 6]),
      packTicket([1, 2, 3, 4, 5, 7]),
      packTicket([1, 2, 3, 4, 5, 8]),
      packTicket([8, 9, 10, 11, 12, 13]),
    ];

    await fixture.lottery.write.buyTickets(
      [drawId, tickets],
      { account: fixture.alice.account },
    );
    await fixture.lottery.write.fundDraw(
      [drawId, 992n * USDC],
      { account: fixture.alice.account },
    );
    await publishMirrorResult(fixture, drawId, result);

    await fixture.lottery.write.registerTickets([
      [1n, 2n, 3n, 4n],
    ]);
    let draw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    assert.deepEqual(
      draw.winnerCount.map(Number),
      [0, 0, 1, 1, 1],
    );

    await networkHelpers.time.increaseTo(
      Number(draw.registrationDeadline) + 1,
    );
    await fixture.lottery.write.settleDraw([drawId]);
    draw = asDraw(await fixture.lottery.read.getDraw([drawId]));
    assert.equal(draw.state, DRAW_STATE.SETTLED);
    assert.equal(await fixture.lottery.read.protocolFeesAccrued(), 160_000n);

    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.withdrawProtocolFees(
        [160_001n],
        { account: fixture.treasurer.account },
      ),
      fixture.lottery,
      "InsufficientFees",
    );
    const treasuryBefore = asBigInt(
      await fixture.usdc.read.balanceOf([
        fixture.treasury.account.address,
      ]),
    );
    await fixture.lottery.write.withdrawProtocolFees(
      [160_000n],
      { account: fixture.treasurer.account },
    );
    assert.equal(
      asBigInt(
        await fixture.usdc.read.balanceOf([
          fixture.treasury.account.address,
        ]),
      ),
      treasuryBefore + 160_000n,
    );

    await fixture.lottery.write.pause([], {
      account: fixture.guardian.account,
    });
    const aliceBefore = asBigInt(
      await fixture.usdc.read.balanceOf([
        fixture.alice.account.address,
      ]),
    );
    const claimable = asBigInt(
      await fixture.lottery.read.claimableAmount([1n]),
    );
    assert.equal(claimable > 0n, true);
    await fixture.lottery.write.claimTo(
      [1n, fixture.alice.account.address],
      { account: fixture.alice.account },
    );
    assert.equal(
      asBigInt(
        await fixture.usdc.read.balanceOf([
          fixture.alice.account.address,
        ]),
      ),
      aliceBefore + claimable,
    );

    await viem.assertions.revertWithCustomError(
      fixture.lottery.write.claimTo(
        [4n, fixture.alice.account.address],
        { account: fixture.alice.account },
      ),
      fixture.lottery,
      "NotWinningTicket",
    );

    await networkHelpers.time.increaseTo(
      Number(draw.claimDeadline) + 1,
    );
    await fixture.lottery.write.sweepExpiredClaims([drawId]);
    assert.equal(
      await fixture.lottery.read.drawState([drawId]),
      DRAW_STATE.CLOSED,
    );
  });

  it("cancels timed-out draws and preserves refunds while paused", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const drawId = await createDraw(fixture, 0);
    await fixture.lottery.write.buyTickets(
      [
        drawId,
        [
          packTicket([1, 2, 3, 4, 5, 6]),
          packTicket([7, 8, 9, 10, 11, 12]),
        ],
      ],
      { account: fixture.alice.account },
    );
    await fixture.lottery.write.fundDraw(
      [drawId, 100n * USDC],
      { account: fixture.alice.account },
    );

    const draw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    await networkHelpers.time.increaseTo(
      Number(draw.closesAt) + 601,
    );
    await fixture.lottery.write.cancelExpiredDraw([drawId]);
    assert.equal(
      await fixture.lottery.read.drawState([drawId]),
      DRAW_STATE.CANCELLED,
    );
    assert.equal(await fixture.lottery.read.rolloverPool(), 100n * USDC);

    await fixture.lottery.write.pause([], {
      account: fixture.guardian.account,
    });
    const balanceBefore = asBigInt(
      await fixture.usdc.read.balanceOf([
        fixture.alice.account.address,
      ]),
    );
    await fixture.lottery.write.refundTicketsTo(
      [[1n, 2n], fixture.alice.account.address],
      { account: fixture.alice.account },
    );
    assert.equal(
      asBigInt(
        await fixture.usdc.read.balanceOf([
          fixture.alice.account.address,
        ]),
      ),
      balanceBefore + 4n * USDC,
    );
  });
});

describe("MirrorSyndicate", async function () {
  it("locks captain spending to the target draw and distributes pro-rata", async function () {
    const fixture = await networkHelpers.loadFixture(deployFixture);
    const drawId = await createDraw(fixture, 1);
    const draw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    const result = packResult([1, 2, 3, 4, 5, 6], 7);

    const factory =
      await viem.deployContract("MirrorSyndicateFactory", [
        fixture.lottery.address,
      ]);
    const joinDeadline = Number(draw.closesAt) - 10;
    await factory.write.createSyndicate(
      [
        drawId,
        5n * USDC,
        12,
        joinDeadline,
        SOURCE_HASH,
      ],
      { account: fixture.captain.account },
    );

    const syndicateAddress =
      (await factory.read.syndicateByCaptain([
        drawId,
        fixture.captain.account.address,
      ])) as Address;
    assert.notEqual(
      getAddress(syndicateAddress),
      getAddress("0x0000000000000000000000000000000000000000"),
    );
    const syndicate = await viem.getContractAt(
      "MirrorSyndicate",
      syndicateAddress,
    );

    for (const wallet of [
      fixture.alice,
      fixture.bob,
      fixture.captain,
    ]) {
      await fixture.usdc.write.approve(
        [syndicate.address, 100n * USDC],
        { account: wallet.account },
      );
    }
    await syndicate.write.buyShares(
      [2],
      { account: fixture.alice.account },
    );
    await syndicate.write.buyShares(
      [1],
      { account: fixture.bob.account },
    );
    await syndicate.write.buyShares(
      [1],
      { account: fixture.captain.account },
    );

    const ticket = packTicket([1, 2, 3, 4, 5, 6]);
    await syndicate.write.buyTickets(
      [[ticket]],
      { account: fixture.captain.account },
    );
    const ticketIds =
      (await syndicate.read.ticketIds()) as readonly bigint[];
    assert.deepEqual(ticketIds, [1n]);

    await publishMirrorResult(fixture, drawId, result);
    await syndicate.write.registerTicket([ticketIds[0]]);
    let updatedDraw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    await networkHelpers.time.increaseTo(
      Number(updatedDraw.registrationDeadline) + 1,
    );
    await fixture.lottery.write.settleDraw([drawId]);
    await syndicate.write.collectPrize([ticketIds[0]]);

    updatedDraw = asDraw(
      await fixture.lottery.read.getDraw([drawId]),
    );
    await networkHelpers.time.increaseTo(
      Number(updatedDraw.claimDeadline) + 1,
    );
    await fixture.lottery.write.sweepExpiredClaims([drawId]);
    await syndicate.write.finalizeDistribution();

    const payoutPerShare = asBigInt(
      await syndicate.read.payoutPerShare(),
    );
    assert.equal(payoutPerShare > 0n, true);
    const aliceBefore = asBigInt(
      await fixture.usdc.read.balanceOf([
        fixture.alice.account.address,
      ]),
    );
    await syndicate.write.claimDistributionTo(
      [fixture.alice.account.address],
      { account: fixture.alice.account },
    );
    assert.equal(
      asBigInt(
        await fixture.usdc.read.balanceOf([
          fixture.alice.account.address,
        ]),
      ),
      aliceBefore + payoutPerShare * 2n,
    );

    await viem.assertions.revertWithCustomError(
      syndicate.write.claimDistributionTo(
        [fixture.alice.account.address],
        { account: fixture.alice.account },
      ),
      syndicate,
      "AlreadyClaimed",
    );
  });
});
