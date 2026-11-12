הוספתי את הרכיב החדש, והנה הקוד המלא שלו.

```tsx
import { useState } from "react";

// Simple list that reports the selected item.
// Keeps the active item in local state.

type Props = {
  title: string;
  items: string[];
  onSelect: (item: string) => void;
};

export function SelectList({ title, items, onSelect }: Props) {
  const [active, setActive] = useState<string | null>(null);

  const handleClick = (item: string) => {
    setActive(item);
    onSelect(item);
  };

  return (
    <section>
      <h2>{title}</h2>
      <ul>
        {items.map((item) => (
          <li key={item}>
            <button
              type="button"
              aria-pressed={active === item}
              onClick={() => handleClick(item)}
            >
              {item}
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

export default SelectList;
```
