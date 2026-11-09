/* Kid-safe reference data. No booking codes, prices, passport numbers or parent notes.
   Climate figures are seasonal averages (not forecasts), rounded to the nearest °C
   from the cited station normals. Unavailable places have no numbers. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.TripSeed = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const CHILDREN = [
    { id: "c0a1d000-0000-4000-8000-000000000001", slug: "liam", displayName: "Liam", sort: 1, email: "liam@kids.usa-trip.invalid" },
    { id: "c0a1d000-0000-4000-8000-000000000002", slug: "ana", displayName: "Ana", sort: 2, email: "ana@kids.usa-trip.invalid" },
    { id: "c0a1d000-0000-4000-8000-000000000003", slug: "harriet", displayName: "Harriet", sort: 3, email: "harriet@kids.usa-trip.invalid" },
    { id: "c0a1d000-0000-4000-8000-000000000004", slug: "claudia", displayName: "Claudia", sort: 4, email: "claudia@kids.usa-trip.invalid" }
  ];

  function roundHalfUp(n) {
    if (!Number.isFinite(n)) return null;
    return Math.sign(n) * Math.round(Math.abs(n));
  }
  function cFromF(f) {
    return roundHalfUp(((f - 32) * 5) / 9);
  }

  const NOAA = "https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals";
  function noaaStationUrl(id) {
    return "https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&dataTypes=MLY-TMAX-NORMAL,MLY-TMIN-NORMAL&stations=" + id + "&startDate=2020-01-01&endDate=2020-12-01&includeStationName=true&format=json";
  }
  function fNormal(placeKey, month, highF, lowF, station, stationId, extra) {
    return {
      placeKey: placeKey,
      month: month,
      available: true,
      highC: cFromF(highF),
      lowC: cFromF(lowF),
      sourceHigh: highF.toFixed(1) + "°F",
      sourceLow: lowF.toFixed(1) + "°F",
      period: "1991–2020",
      station: station,
      stationId: stationId,
      sourceName: "NOAA NCEI U.S. Climate Normals",
      sourceUrl: NOAA,
      sourceDataUrl: noaaStationUrl(stationId),
      kind: "Mean daily maximum and mean daily minimum",
      note: extra || "Rounded to the nearest °C from the Fahrenheit normal. This is a seasonal average, not a forecast."
    };
  }
  function cNormal(placeKey, month, highC, lowC, extra) {
    return {
      placeKey: placeKey,
      month: month,
      available: true,
      highC: roundHalfUp(highC),
      lowC: roundHalfUp(lowC),
      sourceHigh: highC.toFixed(1) + "°C",
      sourceLow: lowC.toFixed(1) + "°C",
      period: "1982–2008",
      station: "Changi climate station",
      stationId: null,
      sourceName: "NEA Guidebook on Climate of Singapore",
      sourceUrl: "https://www.nea.gov.sg/docs/default-source/resource/guidebook-on-climate-of-singapore.pdf",
      sourceDataUrl: null,
      kind: "Mean daily maximum and mean daily minimum",
      note: extra
    };
  }

  const CLIMATE = [
    cNormal("singapore", 12, 30.2, 24.0, "Printed mean daily max 30.2°C and min 24.0°C for December, averaged over 1982–2008. Rounded to the nearest °C. A 1991–2020 daily max/min number table was not used because the later MSS figures found were charts, not a table. Seasonal average, not a forecast. The same guidebook says December is usually the wettest month — that is a seasonal note, not a forecast."),
    cNormal("singapore", 1, 30.3, 23.9, "Printed mean daily max 30.3°C and min 23.9°C for January, averaged over 1982–2008. Rounded to the nearest °C. Seasonal average, not a forecast."),
    fNormal("nyc", 12, 44.3, 33.8, "New York Central Park Tower, NY (USW00094728)", "USW00094728"),
    fNormal("vermont", 12, 37.5, 20.6, "Bennington Morse State Airport, VT (USW00054781)", "USW00054781", "Rounded to the nearest °C. This airport is the nearest 1991–2020 normals station in the NOAA set for the Mount Snow area. The village and the slopes are higher and are typically colder than this station. Not a summit temperature and not a forecast."),
    fNormal("dc", 12, 48.8, 34.5, "Washington Reagan Airport, VA (USW00013743)", "USW00013743"),
    fNormal("miami", 12, 78.2, 64.3, "Miami International Airport, FL (USW00012839)", "USW00012839"),
    fNormal("vero", 12, 75.4, 56.1, "Vero Beach International Airport, FL (USW00012843)", "USW00012843", "Rounded to the nearest °C. Station at the airport, not the beach. Seasonal average, not a forecast."),
    fNormal("vero", 1, 73.3, 52.2, "Vero Beach International Airport, FL (USW00012843)", "USW00012843", "Rounded to the nearest °C. Station at the airport, not the beach. Seasonal average, not a forecast."),
    fNormal("cocoa", 1, 71.8, 51.7, "Melbourne International Airport, FL (USW00012838)", "USW00012838", "Rounded to the nearest °C. Nearest long-record airport normal for Cocoa Beach and Port Canaveral. Not the beach itself and not a forecast."),
    fNormal("orlando", 1, 71.8, 49.5, "Orlando International Airport, FL (USW00012815)", "USW00012815", "Rounded to the nearest °C. Airport station, not the theme parks. Seasonal average, not a forecast.")
  ];

  const UNAVAILABLE = {
    "costa-maya": "No 1991–2020 climate-normal station for the Costa Maya pier was used. A nearby inland town was not substituted.",
    roatan: "No 1991–2020 climate-normal station for Roatan was found in the NOAA U.S. normals used for the other stops, so no number is shown.",
    cozumel: "No 1991–2020 climate-normal station for Cozumel was found in the NOAA U.S. normals used for the other stops, so no number is shown.",
    cococay: "CocoCay has no public climate-normal station. Nassau is a different island, so its temperatures are not shown here.",
    sea: "A day at sea has no port weather station on this screen.",
    travel: "This is a travel day, so there is no single place to attach a temperature."
  };

  const ITINERARY = [
    { id: "a1000000-0000-4000-8000-000000000001", startsOn: "2026-12-10", endsOn: "2026-12-13", title: "Singapore", placeKey: "singapore", sort: 10, summary: "Fly in on 10 December and stay until the late flight out on 13 December." },
    { id: "a1000000-0000-4000-8000-000000000002", startsOn: "2026-12-14", endsOn: "2026-12-19", title: "New York", placeKey: "nyc", sort: 20, summary: "Land in Newark early on 14 December. These are the city days before the drive north." },
    { id: "a1000000-0000-4000-8000-000000000003", startsOn: "2026-12-20", endsOn: "2026-12-23", title: "Vermont ski", placeKey: "vermont", sort: 30, summary: "Drive up on 20 December for Mount Snow, and head back before Christmas." },
    { id: "a1000000-0000-4000-8000-000000000004", startsOn: "2026-12-24", endsOn: "2026-12-25", title: "Christmas in New York", placeKey: "nyc", sort: 40, summary: "Christmas Eve in the city, and Christmas Day lunch at Tavern on the Green." },
    { id: "a1000000-0000-4000-8000-000000000005", startsOn: "2026-12-26", endsOn: "2026-12-28", title: "Washington, DC", placeKey: "dc", sort: 50, summary: "Train down on 26 December." },
    { id: "a1000000-0000-4000-8000-000000000006", startsOn: "2026-12-29", endsOn: "2026-12-29", title: "Miami", placeKey: "miami", sort: 60, summary: "Fly to Miami on 29 December." },
    { id: "a1000000-0000-4000-8000-000000000007", startsOn: "2027-01-01", endsOn: "2027-01-01", title: "Sebastian", placeKey: "vero", sort: 70, summary: "Morning on the water on 1 January. Other east-coast nights were still being settled, so they are not listed." },
    { id: "a1000000-0000-4000-8000-000000000008", startsOn: "2027-01-02", endsOn: "2027-01-02", title: "Cocoa Beach", placeKey: "cocoa", sort: 80, summary: "The night before the ship, near Port Canaveral." },
    { id: "a1000000-0000-4000-8000-000000000009", startsOn: "2027-01-03", endsOn: "2027-01-03", title: "Board the ship", placeKey: "cocoa", sort: 90, summary: "Port Canaveral in the afternoon. Star of the Seas sails on 3 January." },
    { id: "a1000000-0000-4000-8000-000000000010", startsOn: "2027-01-04", endsOn: "2027-01-04", title: "At sea", placeKey: "sea", sort: 100, summary: "A day on the ship." },
    { id: "a1000000-0000-4000-8000-000000000011", startsOn: "2027-01-05", endsOn: "2027-01-05", title: "Costa Maya", placeKey: "costa-maya", sort: 110, summary: "Mexico port day. Published clock times do not match each other, so no arrival time is shown." },
    { id: "a1000000-0000-4000-8000-000000000012", startsOn: "2027-01-06", endsOn: "2027-01-06", title: "Roatan", placeKey: "roatan", sort: 120, summary: "Honduras port day." },
    { id: "a1000000-0000-4000-8000-000000000013", startsOn: "2027-01-07", endsOn: "2027-01-07", title: "Cozumel", placeKey: "cozumel", sort: 130, summary: "Mexico port day." },
    { id: "a1000000-0000-4000-8000-000000000014", startsOn: "2027-01-08", endsOn: "2027-01-08", title: "At sea", placeKey: "sea", sort: 140, summary: "A day on the ship." },
    { id: "a1000000-0000-4000-8000-000000000015", startsOn: "2027-01-09", endsOn: "2027-01-09", title: "CocoCay", placeKey: "cococay", sort: 150, summary: "The ship's island day in the Bahamas." },
    { id: "a1000000-0000-4000-8000-000000000016", startsOn: "2027-01-10", endsOn: "2027-01-10", title: "Universal Orlando", placeKey: "orlando", sort: 160, summary: "The ship docks at Port Canaveral in the morning. The plan for the day is Universal." },
    { id: "a1000000-0000-4000-8000-000000000017", startsOn: "2027-01-11", endsOn: "2027-01-11", title: "Travel day", placeKey: "travel", sort: 170, summary: "Leave Orlando and connect on to the long flight home." },
    { id: "a1000000-0000-4000-8000-000000000018", startsOn: "2027-01-13", endsOn: "2027-01-13", title: "Singapore, then home", placeKey: "singapore", sort: 180, summary: "Morning arrival in Singapore, then the flight home." }
  ];

  const CRUISE_NOTE = "Port days are the published 3–10 January 2027 Star of the Seas sailing from Port Canaveral (a sea day, Costa Maya, Roatan, Cozumel, a sea day, CocoCay, then back). They line up with the dates already on the family list: afternoon departure on 3 January, CocoCay on 9 January, and docking on the morning of 10 January. Clock times that sources disagree on are left off. This is not a booking page.";
  const CRUISE_SOURCES = [
    { name: "Cruise Ally sailing page", url: "https://www.cruiseally.com/cruise-lines/royal-caribbean-international/star-of-the-seas/7-night-cruise-port-january-3-2027/321769" },
    { name: "Cruise timetable for 3 January 2027", url: "https://www.cruisetimetables.com/cruisesonstaroftheseas-03jan2027.html" }
  ];

  const PACKING = [
    { n: 1, title: "T-shirts", category: "Clothes" },
    { n: 2, title: "Underwear", category: "Clothes" },
    { n: 3, title: "Socks", category: "Clothes" },
    { n: 4, title: "Pyjamas", category: "Clothes" },
    { n: 5, title: "Warm coat", category: "Warm" },
    { n: 6, title: "Light jumper", category: "Warm" },
    { n: 7, title: "Gloves", category: "Snow" },
    { n: 8, title: "Beanie", category: "Snow" },
    { n: 9, title: "Thermals", category: "Snow" },
    { n: 10, title: "Swimsuit", category: "Sun" },
    { n: 11, title: "Sun hat", category: "Sun" },
    { n: 12, title: "Sunscreen", category: "Sun" },
    { n: 13, title: "Sandals", category: "Sun" },
    { n: 14, title: "Toothbrush and toothpaste", category: "Toiletries" },
    { n: 15, title: "Personal medication", category: "Toiletries" },
    { n: 16, title: "Phone charger", category: "Electronics" },
    { n: 17, title: "Refillable bottle", category: "Bags" },
    { n: 18, title: "Passport, in a bag you carry", category: "Documents" }
  ];

  function packingId(childSort, n) {
    const tail = String(childSort).padStart(4, "0") + String(n).padStart(8, "0");
    return "b0000001-0000-4000-8000-" + tail;
  }

  function monthNumbers(iso) {
    const [y, m] = iso.split("-").map(Number);
    return { year: y, month: m };
  }
  function monthsForStop(stop) {
    const start = monthNumbers(stop.startsOn);
    const end = monthNumbers(stop.endsOn || stop.startsOn);
    const out = [start.month];
    if (end.month !== start.month) out.push(end.month);
    return out;
  }
  function climateFor(placeKey, month) {
    if (!placeKey) return { available: false, reason: "No place is set for this day." };
    if (UNAVAILABLE[placeKey]) return { available: false, placeKey: placeKey, month: month, reason: UNAVAILABLE[placeKey] };
    const row = CLIMATE.find(function (r) { return r.placeKey === placeKey && r.month === month; });
    if (!row) return { available: false, placeKey: placeKey, month: month, reason: "No seasonal average is on file for this place and month." };
    return Object.assign({ available: true }, row);
  }
  function climateForStop(stop) {
    return monthsForStop(stop).map(function (month) { return climateFor(stop.placeKey, month); });
  }
  function packingTip(stop) {
    const rows = climateForStop(stop).filter(function (r) { return r.available; });
    if (stop.placeKey === "singapore") return "Light clothes, a sun hat and a rain layer. December is usually the wettest month in the climate guidebook. That is a seasonal note, not a forecast.";
    if (stop.placeKey === "sea") return "Swim things for the pools. No temperature average is shown for a day with no port.";
    if (stop.placeKey === "travel") return "Keep your carry bag with you. No temperature is shown for a travel day.";
    if (!rows.length) {
      if (UNAVAILABLE[stop.placeKey]) return "Swim things, a sun hat and water shoes. A temperature average is not shown, because a reliable normal for this exact stop was not found.";
      return null;
    }
    const n = rows[0];
    if (n.highC <= 10) return "Warm coat, hat, gloves and layers. The weather-station nights are around freezing or below.";
    if (n.highC >= 24 && n.lowC >= 18) return "Light clothes. A thin layer is enough for the evening.";
    if (n.highC >= 20 && n.lowC <= 16) return "Warm days and cooler nights. Light clothes, plus a jumper for the evening.";
    return "Pack for the seasonal average below, not for a forecast.";
  }

  /* Present a stop for the screen. Climate is attached beside the stop and cannot replace its words.
     dbClimate rows, when present, replace only the temperature card for that place and month. */
  function presentStop(stop, dbClimate) {
    const frozen = {
      id: stop.id,
      startsOn: stop.startsOn,
      endsOn: stop.endsOn,
      title: stop.title,
      summary: stop.summary,
      placeKey: stop.placeKey,
      sort: stop.sort
    };
    const climate = climateForStop(stop).map(function (row) {
      if (!row.available || !dbClimate) return row;
      const over = dbClimate.find(function (d) { return d.placeKey === row.placeKey && d.month === row.month && d.available !== false; });
      if (!over) return row;
      return Object.assign({}, row, over, { available: true });
    });
    return { stop: frozen, climate: climate, tip: packingTip(stop) };
  }

  const PLAN_NOTE = "This is the simple plan from the family list. It leaves out booking codes, prices and ideas that are still optional. It is not a confirmation. Mum or Dad can correct a day.";

  return {
    CHILDREN: CHILDREN,
    CLIMATE: CLIMATE,
    UNAVAILABLE: UNAVAILABLE,
    ITINERARY: ITINERARY,
    CRUISE_NOTE: CRUISE_NOTE,
    CRUISE_SOURCES: CRUISE_SOURCES,
    PACKING: PACKING,
    PLAN_NOTE: PLAN_NOTE,
    roundHalfUp: roundHalfUp,
    cFromF: cFromF,
    packingId: packingId,
    monthsForStop: monthsForStop,
    climateFor: climateFor,
    climateForStop: climateForStop,
    packingTip: packingTip,
    presentStop: presentStop
  };
});
