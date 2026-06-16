"use client";

import { useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { Check, Copy } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { shortAddr } from "@/lib/utils";

interface QrDisplayProps {
  /** The string payload encoded into the QR code (typically a Sui object id). */
  value: string;
  /** Label shown below the QR (e.g. "Invoice ID"). */
  label?: string;
  /** QR pixel size; default 224 (14rem). */
  size?: number;
}

/**
 * Reusable QR + plain-text-copy widget. Customer scans the QR; cashier can
 * also copy the encoded id to paste over a chat channel as a fallback.
 */
export function QrDisplay({ value, label, size = 224 }: QrDisplayProps) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      toast.success("Copied to clipboard");
      setTimeout(() => setCopied(false), 1500);
    } catch {
      toast.error("Clipboard not available");
    }
  };

  return (
    <div className="flex flex-col items-center gap-4">
      <div className="rounded-lg border border-[color:var(--color-border)] bg-white p-4">
        <QRCodeSVG value={value} size={size} level="M" includeMargin={false} />
      </div>
      {label ? (
        <div className="text-xs font-medium uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
          {label}
        </div>
      ) : null}
      <div className="flex w-full items-center gap-2 rounded-md border border-[color:var(--color-border)] bg-[color:var(--color-muted)] px-3 py-2">
        <code className="flex-1 truncate text-xs">{shortAddr(value, 8)}</code>
        <Button size="sm" variant="ghost" onClick={copy}>
          {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
        </Button>
      </div>
    </div>
  );
}
