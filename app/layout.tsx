import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Mirror Lottery — Provably fair. Seriously fun.",
  description:
    "Play mirrored or fully on-chain lottery draws and create transparent syndicates on Base and Arbitrum.",
  other: {
    "codex-preview": "development",
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
