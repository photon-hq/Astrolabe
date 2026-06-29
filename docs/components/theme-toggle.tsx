'use client';

import type { ThemeSwitchProps } from 'fumadocs-ui/layouts/shared/slots/theme-switch';
import { useTheme } from 'fumadocs-ui/provider/base';
import { Moon, Sun } from 'lucide-react';
import { useEffect, useState } from 'react';

export function ThemeToggle({ className }: ThemeSwitchProps) {
  const { resolvedTheme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  const isDark = mounted ? resolvedTheme !== 'light' : true;
  const Icon = isDark ? Moon : Sun;

  return (
    <div className={className}>
      <button
        aria-label={isDark ? 'Switch to light mode' : 'Switch to dark mode'}
        className="photon-sidebar-button photon-sidebar-button--icon"
        type="button"
        onClick={() => setTheme(isDark ? 'light' : 'dark')}
        data-theme-toggle
      >
        <Icon aria-hidden="true" fill="currentColor" />
      </button>
    </div>
  );
}
