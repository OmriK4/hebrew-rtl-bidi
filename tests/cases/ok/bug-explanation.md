מצאתי את הבאג. הפונקציה `getUser` מחזירה `undefined` כשהמשתמש עדיין לא נטען, והרכיב ניגש ל-`user.name` בלי לבדוק אם הערך קיים.

הסיבה היא שהקריאה ל-`fetch` מתבצעת בתוך `useEffect`, אז הרינדור הראשון תמיד קורה לפני שהנתונים מגיעים. התיקון הוא להוסיף בדיקה קצרה:

```tsx
if (!user) return <Spinner />;
return <h1>{user.name}</h1>;
```

אחרי השינוי השגיאה `Cannot read properties of undefined` נעלמת, והדף נטען כרגיל.
