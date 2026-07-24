"use client";

import type { FormEvent } from "react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

type NetworkKey = "base-sepolia" | "arbitrum-sepolia";

type EthereumProvider = {
  request: (request: {
    method: string;
    params?: unknown[];
  }) => Promise<unknown>;
};

declare global {
  interface Window {
    ethereum?: EthereumProvider;
  }
}

const NETWORKS: Record<
  NetworkKey,
  {
    name: string;
    shortName: string;
    chainId: string;
    nativeCurrency: { name: string; symbol: string; decimals: number };
    rpcUrls: string[];
    blockExplorerUrls: string[];
  }
> = {
  "base-sepolia": {
    name: "Base Sepolia",
    shortName: "Base",
    chainId: "0x14a34",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: ["https://sepolia.base.org"],
    blockExplorerUrls: ["https://sepolia.basescan.org"],
  },
  "arbitrum-sepolia": {
    name: "Arbitrum Sepolia",
    shortName: "Arbitrum",
    chainId: "0x66eee",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: ["https://sepolia-rollup.arbitrum.io/rpc"],
    blockExplorerUrls: ["https://sepolia.arbiscan.io"],
  },
};

const INITIAL_NUMBERS = [9, 17, 28, 33, 42, 47];
const NUMBER_RANGE = Array.from({ length: 49 }, (_, index) => index + 1);
const TICKET_PRICE = 2;
const DRAW_START_SECONDS = 4 * 60 * 60 + 18 * 60 + 22;

function formatCountdown(seconds: number) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainingSeconds = seconds % 60;

  return [hours, minutes, remainingSeconds]
    .map((value) => value.toString().padStart(2, "0"))
    .join(":");
}

function Logo() {
  return (
    <a className="brand" href="#top" aria-label="Mirror Lottery home">
      <span className="brand-mark" aria-hidden="true">
        <span />
        <span />
      </span>
      <span className="brand-copy">
        <strong>Mirror</strong>
        <small>Lottery</small>
      </span>
    </a>
  );
}

function WalletIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24">
      <path d="M4 6.5h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a3 3 0 0 1-3-3v-10a3 3 0 0 1 3-3h11" />
      <path d="M16 11h5v5h-5a2.5 2.5 0 0 1 0-5Z" />
      <path d="M16.2 13.5h.1" />
    </svg>
  );
}

function formatAccount(account: string) {
  return `${account.slice(0, 6)}…${account.slice(-4)}`;
}

export default function Home() {
  const [selectedNumbers, setSelectedNumbers] =
    useState<number[]>(INITIAL_NUMBERS);
  const [network, setNetwork] = useState<NetworkKey>("base-sepolia");
  const [ticketCount, setTicketCount] = useState(1);
  const [account, setAccount] = useState("");
  const [walletBusy, setWalletBusy] = useState(false);
  const [countdown, setCountdown] = useState(DRAW_START_SECONDS);
  const [syndicateOpen, setSyndicateOpen] = useState(false);
  const [syndicateName, setSyndicateName] = useState("Friday Night Crew");
  const [syndicateShares, setSyndicateShares] = useState(12);
  const [sharePrice, setSharePrice] = useState(5);
  const syndicateTriggerRef = useRef<HTMLButtonElement>(null);
  const syndicateCloseRef = useRef<HTMLButtonElement>(null);
  const [notice, setNotice] = useState(
    "Testnet preview — tickets have no monetary value.",
  );

  const total = useMemo(
    () => ticketCount * TICKET_PRICE,
    [ticketCount],
  );
  const syndicatePool = syndicateShares * sharePrice;
  const closeSyndicate = useCallback(() => {
    setSyndicateOpen(false);
    window.requestAnimationFrame(() => syndicateTriggerRef.current?.focus());
  }, []);

  useEffect(() => {
    const timer = window.setInterval(() => {
      setCountdown((current) =>
        current > 0 ? current - 1 : DRAW_START_SECONDS,
      );
    }, 1000);

    return () => window.clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!syndicateOpen) return;

    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    syndicateCloseRef.current?.focus();

    function handleEscape(event: KeyboardEvent) {
      if (event.key === "Escape") closeSyndicate();
    }

    window.addEventListener("keydown", handleEscape);
    return () => {
      window.removeEventListener("keydown", handleEscape);
      document.body.style.overflow = previousOverflow;
    };
  }, [closeSyndicate, syndicateOpen]);

  function toggleNumber(value: number) {
    setSelectedNumbers((current) => {
      if (current.includes(value)) {
        return current.filter((number) => number !== value);
      }
      if (current.length === 6) {
        setNotice("Choose exactly six numbers. Remove one before adding another.");
        return current;
      }
      return [...current, value].sort((a, b) => a - b);
    });
  }

  function quickPick() {
    const pool = [...NUMBER_RANGE];
    const values = new Uint32Array(6);
    window.crypto.getRandomValues(values);

    for (let index = 0; index < values.length; index += 1) {
      const swapIndex = index + (values[index] % (pool.length - index));
      [pool[index], pool[swapIndex]] = [pool[swapIndex], pool[index]];
    }

    setSelectedNumbers(pool.slice(0, 6).sort((a, b) => a - b));
    setNotice("Fresh quick pick generated locally on your device.");
  }

  async function switchNetwork(nextNetwork: NetworkKey) {
    setNetwork(nextNetwork);
    const provider = window.ethereum;
    if (!provider || !account) return;

    const configuration = NETWORKS[nextNetwork];

    try {
      await provider.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: configuration.chainId }],
      });
      setNotice(`Wallet switched to ${configuration.name}.`);
    } catch (error) {
      const providerError = error as { code?: number };
      if (providerError.code !== 4902) {
        setNotice(`Open your wallet to switch to ${configuration.name}.`);
        return;
      }

      await provider.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: configuration.chainId,
            chainName: configuration.name,
            nativeCurrency: configuration.nativeCurrency,
            rpcUrls: configuration.rpcUrls,
            blockExplorerUrls: configuration.blockExplorerUrls,
          },
        ],
      });
      setNotice(`${configuration.name} was added to your wallet.`);
    }
  }

  async function connectWallet() {
    const provider = window.ethereum;
    if (!provider) {
      setNotice(
        "No browser wallet found. Install a compatible wallet to use the testnet.",
      );
      return "";
    }

    setWalletBusy(true);
    try {
      const accounts = (await provider.request({
        method: "eth_requestAccounts",
      })) as string[];
      const nextAccount = accounts[0] ?? "";
      setAccount(nextAccount);

      if (nextAccount) {
        const configuration = NETWORKS[network];
        await provider.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: configuration.chainId }],
        });
        setNotice(`Connected on ${configuration.name}.`);
      }

      return nextAccount;
    } catch {
      setNotice("Wallet connection was cancelled.");
      return "";
    } finally {
      setWalletBusy(false);
    }
  }

  async function preparePurchase() {
    if (selectedNumbers.length !== 6) {
      setNotice("Select six numbers before preparing your ticket.");
      return;
    }

    const connectedAccount = account || (await connectWallet());
    if (!connectedAccount) return;

    setNotice(
      `${ticketCount} testnet ticket${ticketCount === 1 ? "" : "s"} prepared for ${formatAccount(
        connectedAccount,
      )}. Contract submission unlocks after deployment.`,
    );
  }

  async function chooseDraw(nextNetwork: NetworkKey, label: string) {
    await switchNetwork(nextNetwork);
    setNotice(`${label} selected on ${NETWORKS[nextNetwork].name}.`);
    document
      .getElementById("ticket-builder")
      ?.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  async function prepareSyndicate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (syndicateName.trim().length < 3) {
      setNotice("Give your syndicate a name with at least three characters.");
      return;
    }

    const connectedAccount = account || (await connectWallet());
    if (!connectedAccount) return;

    setSyndicateOpen(false);
    setNotice(
      `${syndicateName.trim()} is configured for ${syndicateShares} shares and ${syndicatePool.toFixed(
        2,
      )} test USDC on ${NETWORKS[network].name}. Contract creation unlocks after deployment.`,
    );
  }

  return (
    <main id="top" className="site-shell">
      <header className="site-header">
        <Logo />
        <nav aria-label="Primary navigation">
          <a href="#how-it-works">How it works</a>
          <a href="#draws">Draws</a>
          <a href="#syndicates">Syndicates</a>
          <a href="#security">Security</a>
        </nav>
        <button
          className="wallet-button"
          type="button"
          onClick={connectWallet}
          disabled={walletBusy}
        >
          <WalletIcon />
          {walletBusy
            ? "Connecting…"
            : account
              ? formatAccount(account)
              : "Connect wallet"}
        </button>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-art" aria-hidden="true" />
        <div className="hero-copy">
          <div className="pilot-badge">
            <span />
            Base + Arbitrum Sepolia · Testnet pilot
          </div>
          <h1 id="hero-title">
            Provably fair.
            <span>Seriously fun.</span>
          </h1>
          <p>
            Play official mirrored lottery draws or fully on-chain draws on{" "}
            <strong className="base-text">Base</strong> and{" "}
            <strong className="arbitrum-text">Arbitrum</strong>.
          </p>

          <div className="draw-stats" aria-label="Current draw">
            <article>
              <small>Demo jackpot</small>
              <strong>
                1,245,000 <span>test USDC</span>
              </strong>
            </article>
            <article>
              <small>Next draw</small>
              <strong className="countdown">
                {formatCountdown(countdown)}
              </strong>
            </article>
          </div>

          <div className="hero-actions">
            <a className="primary-action" href="#ticket-builder">
              <span aria-hidden="true">ϟ</span>
              Play the next draw
            </a>
            <a className="secondary-action" href="#syndicates">
              <span className="people-icon" aria-hidden="true">
                ◉◉
              </span>
              Create a syndicate
            </a>
          </div>
        </div>

        <section
          id="ticket-builder"
          className="ticket-console"
          aria-labelledby="ticket-title"
        >
          <div className="number-picker">
            <div className="console-tabs">
              <h2 id="ticket-title">
                <span className="dot-grid" aria-hidden="true" />
                Pick numbers
              </h2>
              <button type="button" onClick={quickPick}>
                <span aria-hidden="true">✦</span>
                Quick pick
              </button>
            </div>

            <div className="number-grid" aria-label="Lottery numbers 1 to 49">
              {NUMBER_RANGE.map((number) => {
                const selected = selectedNumbers.includes(number);
                return (
                  <button
                    key={number}
                    type="button"
                    className={selected ? "is-selected" : ""}
                    aria-pressed={selected}
                    aria-label={`${selected ? "Remove" : "Select"} number ${number}`}
                    onClick={() => toggleNumber(number)}
                  >
                    {number}
                  </button>
                );
              })}
            </div>

            <div className="picker-footer">
              <button
                type="button"
                onClick={() => setSelectedNumbers([])}
              >
                Clear
              </button>
              <button type="button" onClick={quickPick}>
                Randomize <span aria-hidden="true">⤨</span>
              </button>
            </div>
          </div>

          <aside className="ticket-summary" aria-label="Ticket summary">
            <div className="summary-heading">
              <h3>Your picks</h3>
              <strong>{selectedNumbers.length} / 6</strong>
            </div>

            <div className="selected-list">
              <small>Your numbers</small>
              <div>
                {selectedNumbers.length ? (
                  selectedNumbers.map((number) => (
                    <span key={number}>{number}</span>
                  ))
                ) : (
                  <p>Choose six numbers</p>
                )}
              </div>
            </div>

            <fieldset className="network-picker">
              <legend>Network</legend>
              {(Object.keys(NETWORKS) as NetworkKey[]).map((key) => (
                <button
                  key={key}
                  type="button"
                  className={network === key ? "is-active" : ""}
                  aria-pressed={network === key}
                  onClick={() => switchNetwork(key)}
                >
                  <span className={`network-logo ${key}`} aria-hidden="true">
                    {key === "base-sepolia" ? "—" : "A"}
                  </span>
                  {NETWORKS[key].shortName}
                  <span className="radio-indicator" aria-hidden="true" />
                </button>
              ))}
            </fieldset>

            <div className="ticket-stepper">
              <small>Tickets</small>
              <div>
                <button
                  type="button"
                  aria-label="Remove one ticket"
                  onClick={() =>
                    setTicketCount((current) => Math.max(1, current - 1))
                  }
                >
                  −
                </button>
                <strong>{ticketCount}</strong>
                <button
                  type="button"
                  aria-label="Add one ticket"
                  onClick={() =>
                    setTicketCount((current) => Math.min(10, current + 1))
                  }
                >
                  +
                </button>
              </div>
              <p>{TICKET_PRICE.toFixed(2)} test USDC each</p>
            </div>

            <div className="ticket-total">
              <small>Total</small>
              <strong>{total.toFixed(2)} test USDC</strong>
            </div>

            <button
              className="buy-button"
              type="button"
              onClick={preparePurchase}
            >
              Prepare ticket
              <small>Testnet only · no real funds</small>
            </button>
          </aside>
        </section>
      </section>

      <section className="trust-ribbon" aria-label="Trust and security">
        <article>
          <span className="trust-icon chain-icon" aria-hidden="true" />
          <div>
            <strong>Chainlink VRF</strong>
            <p>Verifiable randomness for fully on-chain draws.</p>
          </div>
        </article>
        <article>
          <span className="trust-icon lock-icon" aria-hidden="true" />
          <div>
            <strong>Contract escrow</strong>
            <p>Funds move only through published draw rules.</p>
          </div>
        </article>
        <article>
          <span className="trust-icon audit-icon" aria-hidden="true" />
          <div>
            <strong>Auditable</strong>
            <p>Open contracts. Verify every draw.</p>
          </div>
        </article>
      </section>

      <section
        id="how-it-works"
        className="content-section how-section"
        aria-labelledby="how-title"
      >
        <div className="section-kicker">
          <span>01</span>
          One simple flow
        </div>
        <div className="section-heading">
          <h2 id="how-title">
            Pick. Play.
            <span>Prove.</span>
          </h2>
          <p>
            Every ticket, result, and payout can be followed on-chain. Choose
            solo play or pool entries with friends without giving up custody.
          </p>
        </div>

        <div className="steps-grid">
          <article>
            <span className="step-number">01</span>
            <div className="step-symbol coral-symbol" aria-hidden="true">
              6
            </div>
            <h3>Choose your six</h3>
            <p>
              Pick six unique numbers or use a local quick pick. Select Base or
              Arbitrum Sepolia and review the cost before signing.
            </p>
          </article>
          <article>
            <span className="step-number">02</span>
            <div className="step-symbol violet-symbol" aria-hidden="true">
              ⛓
            </div>
            <h3>Watch the draw</h3>
            <p>
              Play a VRF-powered draw or follow a mirrored official result with
              dual attestation and a public challenge delay.
            </p>
          </article>
          <article>
            <span className="step-number">03</span>
            <div className="step-symbol lime-symbol" aria-hidden="true">
              ↗
            </div>
            <h3>Claim directly</h3>
            <p>
              Winners use bounded, pull-based claims. No administrator picks a
              winner or loops through every player to send prizes.
            </p>
          </article>
        </div>
      </section>

      <section
        id="draws"
        className="content-section draws-section"
        aria-labelledby="draws-title"
      >
        <div className="section-kicker">
          <span>02</span>
          Two ways to play
        </div>
        <div className="section-heading compact-heading">
          <h2 id="draws-title">
            Your draw.
            <span>Your rules.</span>
          </h2>
          <p>
            Both modes use the same transparent ticket and claim flow. Their
            result trust models are deliberately different and clearly labeled.
          </p>
        </div>

        <div className="draw-card-grid">
          <article className="draw-card onchain-card">
            <div className="draw-card-topline">
              <span className="mode-chip mode-vrf">
                <i />
                Fully on-chain
              </span>
              <span className="network-mini base-mini">Base</span>
            </div>
            <div className="draw-orbit" aria-hidden="true">
              <span>17</span>
            </div>
            <p className="draw-code">DRAW / VRF-0042</p>
            <h3>Friday Night Pulse</h3>
            <p className="draw-description">
              A native crypto draw using Chainlink VRF v2.5 randomness. The
              callback records randomness; anyone can finalize the result.
            </p>
            <dl className="draw-details">
              <div>
                <dt>Demo pool</dt>
                <dd>245,800 test USDC</dd>
              </div>
              <div>
                <dt>Closes in</dt>
                <dd>{formatCountdown(countdown)}</dd>
              </div>
            </dl>
            <button
              type="button"
              onClick={() =>
                chooseDraw("base-sepolia", "Friday Night Pulse")
              }
            >
              Pick this draw <span aria-hidden="true">→</span>
            </button>
          </article>

          <article className="draw-card mirror-card">
            <div className="draw-card-topline">
              <span className="mode-chip mode-mirror">
                <i />
                Mirrored result
              </span>
              <span className="network-mini arbitrum-mini">Arbitrum</span>
            </div>
            <div className="mirror-wave" aria-hidden="true">
              <span>09</span>
              <i />
              <span>09</span>
            </div>
            <p className="draw-code">DRAW / MIRROR-0188</p>
            <h3>Global Saturday Mirror</h3>
            <p className="draw-description">
              Mirrors a published external lottery result. A publisher and an
              independent verifier must agree before the challenge clock starts.
            </p>
            <dl className="draw-details">
              <div>
                <dt>Demo pool</dt>
                <dd>999,200 test USDC</dd>
              </div>
              <div>
                <dt>Trust model</dt>
                <dd>2-party attestation</dd>
              </div>
            </dl>
            <button
              type="button"
              onClick={() =>
                chooseDraw("arbitrum-sepolia", "Global Saturday Mirror")
              }
            >
              Pick this draw <span aria-hidden="true">→</span>
            </button>
          </article>
        </div>

        <div className="truth-note">
          <strong>Know what you&apos;re playing.</strong>
          <p>
            VRF draws inherit the oracle&apos;s verifiable randomness model.
            Mirrored draws rely on named publisher and verifier roles plus a
            challenge window. The app never presents those as equivalent.
          </p>
        </div>
      </section>

      <section
        id="syndicates"
        className="content-section syndicate-section"
        aria-labelledby="syndicate-title"
      >
        <div className="syndicate-copy">
          <div className="section-kicker">
            <span>03</span>
            Play together
          </div>
          <h2 id="syndicate-title">
            More numbers.
            <span>Shared transparently.</span>
          </h2>
          <p>
            Create a one-draw pool, invite members, and buy more combinations.
            Fixed-price shares and prize splits live in the contract—not a
            spreadsheet or someone&apos;s wallet.
          </p>
          <ul>
            <li>
              <span aria-hidden="true">✓</span>
              One clear share price and member cap
            </li>
            <li>
              <span aria-hidden="true">✓</span>
              Captain can only buy tickets for the target draw
            </li>
            <li>
              <span aria-hidden="true">✓</span>
              Members claim their pro-rata prize directly
            </li>
          </ul>
          <button
            ref={syndicateTriggerRef}
            className="syndicate-cta"
            type="button"
            onClick={() => setSyndicateOpen(true)}
          >
            Build a syndicate <span aria-hidden="true">→</span>
          </button>
        </div>

        <div className="syndicate-demo" aria-label="Example syndicate">
          <div className="demo-header">
            <div>
              <small>Example pool</small>
              <h3>Friday Night Crew</h3>
            </div>
            <span>Open</span>
          </div>
          <div className="member-orbit" aria-hidden="true">
            <span className="member member-one">J</span>
            <span className="member member-two">M</span>
            <span className="member member-three">A</span>
            <span className="member member-four">+</span>
            <div>
              <strong>8 / 12</strong>
              <small>shares filled</small>
            </div>
          </div>
          <div className="pool-progress" aria-label="Eight of twelve shares filled">
            <span />
          </div>
          <dl>
            <div>
              <dt>Share price</dt>
              <dd>5 test USDC</dd>
            </div>
            <div>
              <dt>Pool at capacity</dt>
              <dd>60 test USDC</dd>
            </div>
            <div>
              <dt>Target draw</dt>
              <dd>VRF-0042 · Base</dd>
            </div>
          </dl>
          <p className="demo-footnote">
            Preview data only. No testnet syndicate has been created.
          </p>
        </div>
      </section>

      <section
        id="security"
        className="content-section security-section"
        aria-labelledby="security-title"
      >
        <div className="security-intro">
          <div className="section-kicker">
            <span>04</span>
            Built for scrutiny
          </div>
          <h2 id="security-title">
            Fun outside.
            <span>Serious underneath.</span>
          </h2>
          <p>
            The rebuild removes owner-selected winners and unbounded payout
            loops. Administrative powers are separated, delayed, and documented
            for an independent review.
          </p>
        </div>

        <div className="security-grid">
          <article>
            <span className="security-index">A</span>
            <h3>Pull-based prizes</h3>
            <p>
              Each winning ticket claims independently. Large participation
              cannot turn settlement into one oversized transaction.
            </p>
          </article>
          <article>
            <span className="security-index">B</span>
            <h3>Separated roles</h3>
            <p>
              Draw management, result publication, verification, pausing, and
              treasury duties have distinct permissions.
            </p>
          </article>
          <article>
            <span className="security-index">C</span>
            <h3>Constrained custody</h3>
            <p>
              Safe token transfers, exact-balance checks, per-draw accounting,
              and no administrator withdrawal from active prize pools.
            </p>
          </article>
          <article>
            <span className="security-index">D</span>
            <h3>Failure paths</h3>
            <p>
              Timeout cancellation, per-ticket refunds, pause-safe claims, and
              rollover handling are explicit contract states.
            </p>
          </article>
        </div>

        <div className="audit-banner">
          <div>
            <span className="audit-state">
              <i />
              Audit status
            </span>
            <strong>Testnet hardening in progress</strong>
          </div>
          <p>
            Internal tests and static analysis are not an independent audit.
            Mainnet deployment is blocked pending third-party review, fixes, and
            applicable legal and responsible-play checks.
          </p>
        </div>
      </section>

      <section className="network-band" aria-label="Supported pilot networks">
        <p>Built testnet-first for</p>
        <div>
          <span>
            <i className="network-logo base-sepolia">—</i>
            Base Sepolia
          </span>
          <span>
            <i className="network-logo arbitrum-sepolia">A</i>
            Arbitrum Sepolia
          </span>
          <span className="mainnet-later">Mainnet after audit</span>
        </div>
      </section>

      <footer className="site-footer">
        <Logo />
        <div>
          <p>
            Testnet software only. Test USDC has no monetary value. Lottery
            access may be restricted by local law and age requirements.
          </p>
          <span>© 2026 Mirror Lottery · Play transparently.</span>
        </div>
        <a href="#top">Back to top ↑</a>
      </footer>

      {syndicateOpen ? (
        <div
          className="modal-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeSyndicate();
          }}
        >
          <section
            className="syndicate-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="syndicate-modal-title"
          >
            <div className="modal-heading">
              <div>
                <span>Testnet builder</span>
                <h2 id="syndicate-modal-title">Create your syndicate</h2>
              </div>
              <button
                ref={syndicateCloseRef}
                type="button"
                aria-label="Close syndicate builder"
                onClick={closeSyndicate}
              >
                ×
              </button>
            </div>

            <form onSubmit={prepareSyndicate}>
              <label>
                Syndicate name
                <input
                  type="text"
                  maxLength={40}
                  value={syndicateName}
                  onChange={(event) => setSyndicateName(event.target.value)}
                />
              </label>

              <div className="modal-two-column">
                <label>
                  Maximum shares
                  <select
                    value={syndicateShares}
                    onChange={(event) =>
                      setSyndicateShares(Number(event.target.value))
                    }
                  >
                    <option value={6}>6 shares</option>
                    <option value={12}>12 shares</option>
                    <option value={20}>20 shares</option>
                    <option value={25}>25 shares</option>
                  </select>
                </label>
                <label>
                  Price per share
                  <select
                    value={sharePrice}
                    onChange={(event) =>
                      setSharePrice(Number(event.target.value))
                    }
                  >
                    <option value={2}>2 test USDC</option>
                    <option value={5}>5 test USDC</option>
                    <option value={10}>10 test USDC</option>
                  </select>
                </label>
              </div>

              <fieldset className="modal-networks">
                <legend>Network</legend>
                {(Object.keys(NETWORKS) as NetworkKey[]).map((key) => (
                  <button
                    key={key}
                    type="button"
                    className={network === key ? "is-active" : ""}
                    aria-pressed={network === key}
                    onClick={() => switchNetwork(key)}
                  >
                    <span className={`network-logo ${key}`} aria-hidden="true">
                      {key === "base-sepolia" ? "—" : "A"}
                    </span>
                    {NETWORKS[key].name}
                  </button>
                ))}
              </fieldset>

              <div className="syndicate-total">
                <span>
                  <small>Pool at capacity</small>
                  <strong>{syndicatePool.toFixed(2)} test USDC</strong>
                </span>
                <span>
                  <small>Your captain share</small>
                  <strong>1 / {syndicateShares}</strong>
                </span>
              </div>

              <button className="create-syndicate-button" type="submit">
                Prepare syndicate
                <small>No transaction is submitted in this preview</small>
              </button>
            </form>
          </section>
        </div>
      ) : null}

      <div className="status-toast" role="status" aria-live="polite">
        <span />
        {notice}
      </div>
    </main>
  );
}
