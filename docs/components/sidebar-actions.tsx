import { ThemeToggle } from '@/components/theme-toggle';
import { gitConfig } from '@/lib/shared';

export function SidebarActions() {
  return (
    <div className="photon-sidebar-actions">
      <a
        className="photon-sidebar-button photon-sidebar-button--secondary photon-sidebar-button--arrow"
        href={`https://github.com/${gitConfig.user}/${gitConfig.repo}`}
        target="_blank"
        rel="noreferrer noopener"
      >
        GitHub
      </a>
      <ThemeToggle />
    </div>
  );
}
