export type Appearance = 'light' | 'dark';

const storageKey = '3d-model-anything-appearance';

/** Bind a persistent light/dark switch, following the system until the user chooses a mode. */
export function installAppearanceToggle(button: HTMLButtonElement, onChange: (appearance: Appearance) => void = () => {}) {
  const media = window.matchMedia('(prefers-color-scheme: dark)');

  const apply = () => {
    const saved = localStorage.getItem(storageKey);
    const appearance: Appearance = saved === 'light' || saved === 'dark'
      ? saved
      : media.matches ? 'dark' : 'light';
    document.documentElement.dataset.theme = appearance;
    button.textContent = appearance === 'dark' ? '☀ Light' : '☾ Dark';
    button.setAttribute('aria-label', `Switch to ${appearance === 'dark' ? 'light' : 'dark'} appearance`);
    button.title = `Switch to ${appearance === 'dark' ? 'light' : 'dark'} appearance`;
    onChange(appearance);
    window.dispatchEvent(new Event('appearancechange'));
  };

  button.addEventListener('click', () => {
    const current = document.documentElement.dataset.theme;
    localStorage.setItem(storageKey, current === 'dark' ? 'light' : 'dark');
    apply();
  });
  media.addEventListener('change', () => {
    if (!localStorage.getItem(storageKey)) apply();
  });
  window.addEventListener('storage', event => {
    if (event.key === storageKey) apply();
  });
  apply();
}
