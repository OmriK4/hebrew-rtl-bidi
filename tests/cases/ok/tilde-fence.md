כך נראית ההגדרה בקובץ התצורה:

~~~yaml
name: deploy
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
~~~

אחרי המיזוג הפריסה תתחיל אוטומטית.
