import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium transition-colors",
  {
    variants: {
      variant: {
        default: "bg-[color:var(--color-primary)]/15 text-[color:var(--color-primary)]",
        accent: "bg-[color:var(--color-accent)]/30 text-[color:var(--color-accent-foreground)]",
        outline: "border border-[color:var(--color-border)] text-[color:var(--color-foreground)]",
        muted: "bg-[color:var(--color-muted)] text-[color:var(--color-muted-foreground)]",
        destructive: "bg-[color:var(--color-destructive)]/15 text-[color:var(--color-destructive)]",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

export function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />;
}
