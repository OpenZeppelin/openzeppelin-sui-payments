"use client";

import { useState } from "react";
import { Scanner } from "@yudiel/react-qr-scanner";
import { Camera, ClipboardPaste } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

interface QrScannerProps {
  /** Called once a valid id-shaped string has been scanned or pasted. */
  onResult: (value: string) => void;
  /** Optional placeholder for the paste field. */
  placeholder?: string;
}

/**
 * Camera scanner + paste fallback. Tries the camera first; if the user denies
 * permission or there's no camera (desktop), the paste input is the path.
 */
export function QrScanner({ onResult, placeholder = "Paste ID" }: QrScannerProps) {
  const [cameraActive, setCameraActive] = useState(false);
  const [pasted, setPasted] = useState("");
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="flex flex-col gap-4">
      {cameraActive ? (
        <div className="overflow-hidden rounded-lg border border-[color:var(--color-border)]">
          <Scanner
            onScan={(codes) => {
              const v = codes[0]?.rawValue;
              if (v) {
                setCameraActive(false);
                onResult(v.trim());
              }
            }}
            onError={(e) => {
              setError(e instanceof Error ? e.message : "Camera error");
              setCameraActive(false);
            }}
            constraints={{ facingMode: "environment" }}
            classNames={{ container: "aspect-square w-full" }}
          />
        </div>
      ) : (
        <Button
          variant="outline"
          size="lg"
          className="w-full justify-center"
          onClick={() => {
            setError(null);
            setCameraActive(true);
          }}
        >
          <Camera className="h-4 w-4" />
          Scan with camera
        </Button>
      )}

      {error ? (
        <p className="text-xs text-[color:var(--color-destructive)]">{error}</p>
      ) : null}

      <div className="flex items-center gap-2">
        <div className="h-px flex-1 bg-[color:var(--color-border)]" />
        <span className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
          or
        </span>
        <div className="h-px flex-1 bg-[color:var(--color-border)]" />
      </div>

      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          const v = pasted.trim();
          if (v) onResult(v);
        }}
      >
        <Input
          value={pasted}
          onChange={(e) => setPasted(e.target.value)}
          placeholder={placeholder}
          className="flex-1"
        />
        <Button type="submit" variant="secondary">
          <ClipboardPaste className="h-4 w-4" />
          Submit
        </Button>
      </form>
    </div>
  );
}
