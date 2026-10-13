# Which weather source is most accurate for General Santos (method note)

Written 2026-10-13, Cascade Staff v5 lane B. No result is claimed here: nothing below was measured. This is the method to run, and what the code already tells us.

## What the code establishes today (read, not measured)

- `weather-proxy` tries PirateWeather, then Google Weather, then Open-Meteo, and stops at the first that answers. With `PIRATE_WEATHER_API_KEY` set, Pirate wins every time it is up. The order is a design choice. Nobody compared the sources for this house.
- `weather_proxy_cache` in `app_settings` is ONE row that every refresh overwrites. It holds only the latest `source`, so it is not a history. A "source history" cannot be read from it.
- What does leave a trail: the function logs one line per refresh (`cached fresh data, source=...`) and one per failed source (`PirateWeather failed -> trying Google Weather`). Supabase function logs show how often each source was the one used. That shows availability, not accuracy.
- Since lane B, `hourly` comes from Google Weather `forecast/hours:lookup` (Open-Meteo hourly when Google is down), and the cache records which one in `hourly_source`. `rain_watch` uses the same 70 percent threshold as `rain-alert`.
- The three sources do not forecast the same thing: Pirate and Open-Meteo are model blends, Google's hourly gives a rain probability and an `mm` quantity, Open-Meteo's `precipitation` is model rainfall. Compare like with like: "did it rain in that hour at all", not probability against millimetres.

## Method (about 5 minutes a day for 5 to 7 days, free tier, read-only)

1. Each morning at about 06:00 Manila, save the next-12-hour rain figures from each source. Three plain GET calls, no writes, nothing stored on the server:
   - Google: `https://weather.googleapis.com/v1/forecast/hours:lookup?key=<GOOGLE_WEATHER_API_KEY>&location.latitude=6.1164&location.longitude=125.1716&hours=24` (key from the password manager, never pasted into a note).
   - Open-Meteo: `https://api.open-meteo.com/v1/forecast?latitude=6.1164&longitude=125.1716&hourly=precipitation_probability,precipitation&timezone=Asia%2FManila&forecast_days=2`.
   - Pirate: `https://api.pirateweather.net/forecast/<PIRATE_WEATHER_API_KEY>/6.1164,125.1716?units=si&exclude=minutely,daily,alerts` (use `hourly`).
   Paste the three results into one sheet, one row per hour, one column per source.
2. The next day, record what actually happened for each of those hours. Two free references: Open-Meteo's historical API (`https://archive-api.open-meteo.com/v1/archive?...&hourly=precipitation`, reanalysis, a day or two behind) and, better, the house's own record: the cleaner's photos and the turnover notes show wet days, and Lloyd's own view of the sky.
3. Score each source on the same two questions, per day:
   - Of the hours it called 70 percent or more (the `rain_watch` rule), how many were wet? (false alarms)
   - Of the hours that were wet, how many did it call 70 percent or more? (misses)
4. The source with the fewest misses wins for the turnover use. A false alarm costs a rain check at the house; a miss costs wet linen. Weight misses higher.
5. Also count, from the function logs, how often each source was down in the same days. A slightly less accurate source that is always up can beat a better one that fails.

## What would change the code

If one source clearly wins, change only the order of the chain in `weather-proxy` (one `fetchPirateWeather` / `fetchGoogleWeather` / `fetchOpenMeteo` sequence). The `hourly` fallback order (Google, then Open-Meteo) lives in `_shared/B_weather.ts` `B_extras`. Rain-watch and `rain-alert` share `RAIN_THRESHOLD`; change the number there once if the days show 70 is too late or too jumpy.

## Not done in this lane

No history table, no scheduled sampler: a sampler would be new server code for a question that five days of manual rows can answer. Add one only if the answer is "it varies by season".
