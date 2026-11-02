//+------------------------------------------------------------------+
//|                                                  GridStopEA.mq5  |
//|  Symmetric Buy Stop / Sell Stop grid with tiered lots,           |
//|  per-position trailing stop, level re-placement and a basket     |
//|  profit target that closes everything and re-centres the grid.   |
//+------------------------------------------------------------------+
#property copyright "Buy-stop-sell-stop"
#property version   "1.00"
// GridStopEA_Cent.mq5 defines GSE_CENT and GridStopEA_BTC.mq5 defines GSE_BTC,
// then each includes this file.
#ifdef GSE_CENT
#property description "Buy Stop / Sell Stop grid EA (XAUUSD), cent account version. Money inputs are in cents (USC)."
#define GSE_NAME   "GridStopEA Cent"
#define GSE_MAGIC  26011002
#define GSE_PREFIX "STRc"
#else
#ifdef GSE_BTC
#property description "Buy Stop / Sell Stop grid EA (BTCUSD), defaults for a $1000 account."
#define GSE_NAME   "GridStopEA BTC"
#define GSE_MAGIC  26011003
#define GSE_PREFIX "STRb"
#else
#property description "Buy Stop / Sell Stop grid EA (XAUUSD)"
#define GSE_NAME   "GridStopEA"
#define GSE_MAGIC  26011001
#define GSE_PREFIX "STR"
#endif
#endif

// Default inputs. BTC moves in dollars where gold moves in cents, so the
// price-unit defaults are scaled up; lots are the broker minimum for $1000.
#ifdef GSE_BTC
#define GSE_STEP_PCT   0.06   // 100000 -> 60
#define GSE_STEP_FIXED 60.0
#define GSE_LOT1       0.01
#define GSE_LOT2       0.01
#define GSE_LOT3       0.02
#define GSE_TARGET     3.0
#define GSE_MAXLOSS    100.0
#define GSE_BE_OFFSET  2.0
#define GSE_TREND_TGT  10.0
#define GSE_SPREAD     30.0
#define GSE_SLIPPAGE   20.0
#else
#define GSE_STEP_PCT   0.0333 // 4020 -> 1.34
#define GSE_STEP_FIXED 1.34
#define GSE_LOT1       0.01
#define GSE_LOT2       0.05
#define GSE_LOT3       0.20
#define GSE_TARGET     6.0
#define GSE_MAXLOSS    0.0
#define GSE_BE_OFFSET  0.05
#define GSE_TREND_TGT  100.0
#define GSE_SPREAD     0.50
#define GSE_SLIPPAGE   0.30
#endif

#include <Trade\Trade.mqh>

enum ENUM_STEP_MODE
  {
   STEP_PERCENT = 0, // % of price
   STEP_FIXED   = 1  // Fixed price distance
  };

enum ENUM_CENTER_PRICE
  {
   CENTER_BID = 0, // Bid
   CENTER_ASK = 1, // Ask
   CENTER_MID = 2  // (Bid+Ask)/2
  };

enum ENUM_GRID_STATE
  {
   ST_IDLE    = 0,
   ST_ACTIVE  = 1,
   ST_CLOSING = 2
  };

enum ENUM_NEWS_ACTION
  {
   NEWS_BLOCK_NEW      = 0, // Only block new grids
   NEWS_DELETE_PENDING = 1, // Delete pending orders, keep positions
   NEWS_CLOSE_ALL      = 2, // Close everything
   NEWS_TREND          = 3  // Keep trading, allow trend mode
  };

enum ENUM_TREND_SWITCH
  {
   TREND_ALWAYS = 0, // Always (whenever a big lot opens)
   TREND_AUTO   = 1  // Only on news, fast market or trend hours
  };

//--- Grid
input group "Grid"
input ENUM_STEP_MODE    InpStepMode     = STEP_PERCENT; // Step mode
input double            InpStepPercent  = GSE_STEP_PCT; // Step % of price
input double            InpStepFixed    = GSE_STEP_FIXED; // Fixed step (price units)
input ENUM_CENTER_PRICE InpCenterPrice  = CENTER_BID;   // Grid centre price
input int               InpTier1Levels  = 10;           // Tier 1 levels per side
input double            InpTier1Lot     = GSE_LOT1;     // Tier 1 lot
input int               InpTier2Levels  = 10;           // Tier 2 levels per side
input double            InpTier2Lot     = GSE_LOT2;     // Tier 2 lot
input int               InpTier3Levels  = 10;           // Tier 3 levels per side
input double            InpTier3Lot     = GSE_LOT3;     // Tier 3 lot
input bool              InpReplaceLevels = true;        // Re-place stop order on an emptied level

//--- Basket
input group "Basket"
input double InpBasketTarget     = GSE_TARGET;   // Close all when cycle profit >= (money)
input bool   InpIncludeCosts     = false; // Count commission/swap in cycle profit
input double InpMaxLoss          = GSE_MAXLOSS;   // Close all when cycle loss >= (money, 0 = off)
input bool   InpPauseAfterMaxLoss = true; // Stop opening new grids after max loss

//--- Trailing
input group "Trailing stop"
input bool   InpTrailEnable        = true; // Enable trailing stop
input double InpTrailStartSteps    = 2.0;  // Start trailing after profit of N steps
input double InpTrailDistanceSteps = 2.0;  // Trail distance from price (steps)
input double InpTrailTightenSteps  = 3.0;  // Tighten trail after profit of N steps (0 = off)
input double InpTrailTightDistSteps = 1.0; // Tightened trail distance (steps)
input double InpBreakevenOffset    = GSE_BE_OFFSET; // Minimum locked profit (price units)
input double InpTrailMinMoveSteps  = 0.05; // Minimum SL move (steps)

//--- Trend mode
input group "Trend mode"
input bool   InpTrendEnable      = true;  // Enable trend mode
input int    InpTrendTier        = 2;     // Activates when a position of this tier is open
input bool   InpTrendNoTrail     = true;  // Disable trailing in trend mode
input double InpTrendTarget      = GSE_TREND_TGT; // Trend mode: start locking at profit (money)
input double InpTrendGivebackPct = 30.0;  // Trend mode: close after giving back % of peak
input ENUM_TREND_SWITCH InpTrendSwitch = TREND_AUTO; // When trend mode may start
input int    InpVolMinutes       = 15;    // Fast market: look back N minutes
input double InpVolSteps         = 10.0;  // Fast market: price range >= N steps (0 = off)
input bool   InpTrendUseHours    = false; // Allow trend mode inside fixed hours
input int    InpTrendStartHour   = 13;    // Trend hours start (server time)
input int    InpTrendEndHour     = 15;    // Trend hours end (server time)

//--- Filters
input group "Filters"
input double InpMaxSpread     = GSE_SPREAD;  // Max spread for a new grid (price units, 0 = off)
input bool InpDailyClose      = false; // Close everything once a day (before rollover)
input int  InpDailyHour       = 21;    // Daily close hour (server time)
input int  InpDailyMinute     = 0;     // Daily close minute
input int  InpDailyPauseMin   = 1;     // No new grid for N minutes after daily close
input bool InpFridayClose     = false; // Close everything on Friday
input int  InpFridayHour      = 21;    // Friday close hour (server time)
input int  InpFridayMinute    = 0;     // Friday close minute
input bool InpUseHours        = false; // Only start new grids inside hours
input int  InpStartHour       = 1;     // Start hour (server time)
input int  InpEndHour         = 23;    // End hour (server time)

//--- News
input group "News filter (live only, not in tester)"
input bool                            InpNewsFilter     = true;                     // Enable news filter
input string                          InpNewsCurrencies = "USD";                    // Currencies (comma separated)
input ENUM_CALENDAR_EVENT_IMPORTANCE  InpNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum importance
input int                             InpNewsBeforeMin  = 30;                       // Minutes before news
input int                             InpNewsAfterMin   = 30;                       // Minutes after news
input ENUM_NEWS_ACTION                InpNewsAction     = NEWS_TREND;               // Action in news window

//--- Execution
input group "Execution"
input ulong  InpMagic          = GSE_MAGIC;  // Magic number
input string InpCommentPrefix  = GSE_PREFIX; // Order comment prefix
input bool   InpAsync          = true;     // Asynchronous orders (faster)
input double InpMaxSlippage    = GSE_SLIPPAGE;     // Max slippage (price units)
input int    InpTimerMs        = 200;      // Timer interval (ms)
input bool   InpShowPanel      = true;     // Show info panel

CTrade               g_trade;
ENUM_GRID_STATE      g_state      = ST_IDLE;
ENUM_ORDER_TYPE_TIME g_typeTime   = ORDER_TIME_GTC;
double               g_center     = 0.0;
double               g_step       = 0.0;
double               g_tickSize   = 0.0;
long                 g_cycleStartMsc = 0;
double               g_realized   = 0.0;
bool                 g_realizedDirty = true;
double               g_peak       = 0.0;
bool                 g_trendLatch = false; // trend mode engaged in this cycle
string               g_trendWhy   = "";
bool                 g_paused     = false;
int                  g_levels     = 0;   // levels per side
string               g_gvPrefix   = "";

ulong g_cycleStartLocal  = 0;
ulong g_lastRealizedCalc = 0;
ulong g_lastCloseReq     = 0;
ulong g_lastStartTry     = 0;
ulong g_lastPanel        = 0;

// Per-level scratch state. Slot = side * g_levels + (n - 1), side 0 = buy, 1 = sell.
bool  g_hasOrd[];
bool  g_hasPos[];
bool  g_placedOnce[];
ulong g_reqTime[];

// Trailing request throttle per position
ulong  g_trailTicket[];
ulong  g_trailTime[];
double g_trailSl[];

// Upcoming news times (server time) and when they were last loaded
datetime g_newsTimes[];
ulong    g_lastNewsLoad   = 0;
bool     g_newsAvailable  = true;
ulong    g_lastNewsDelete = 0;

// Panel values
double g_lastFloating = 0.0;
int    g_lastPositions = 0;
int    g_lastOrders    = 0;
bool   g_lastTrend     = false;
string g_lastBlock     = "";

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NormPrice(const double price)
  {
   return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, _Digits);
  }

double NormStep(const double step)
  {
   return MathMax(g_tickSize, NormPrice(step));
  }

double NormLot(double lot)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;
   lot = MathRound(lot / step) * step;
   lot = MathMax(vmin, MathMin(vmax, lot));
   return NormalizeDouble(lot, 8);
  }

double StopsDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stops, freeze) + 1) * _Point;
  }

int LevelTier(const int n)
  {
   if(n <= InpTier1Levels)
      return 1;
   if(n <= InpTier1Levels + InpTier2Levels)
      return 2;
   return 3;
  }

double LevelLot(const int n)
  {
   int tier = LevelTier(n);
   if(tier == 1)
      return InpTier1Lot;
   if(tier == 2)
      return InpTier2Lot;
   return InpTier3Lot;
  }

double LevelPrice(const int side, const int n)
  {
   double offset = n * g_step;
   return NormPrice(side == 0 ? g_center + offset : g_center - offset);
  }

int Slot(const int side, const int n)
  {
   return side * g_levels + (n - 1);
  }

string LevelComment(const int side, const int n)
  {
   return StringFormat("%s %s%d", InpCommentPrefix, side == 0 ? "B" : "S", n);
  }

// Parses "STR B5" / "STR S12" into side and level number.
bool ParseComment(const string comment, int &side, int &n)
  {
   string head = InpCommentPrefix + " ";
   if(StringFind(comment, head) != 0 || StringLen(comment) < StringLen(head) + 2)
      return false;
   ushort c = StringGetCharacter(comment, StringLen(head));
   if(c == 'B')
      side = 0;
   else
      if(c == 'S')
         side = 1;
      else
         return false;
   n = (int)StringToInteger(StringSubstr(comment, StringLen(head) + 1));
   return (n >= 1 && n <= g_levels);
  }

// Finds the grid level of an order/position: comment first, price as fallback.
bool LevelOf(const bool isBuy, const string comment, const double price, int &side, int &n)
  {
   if(ParseComment(comment, side, n) && side == (isBuy ? 0 : 1))
      return true;
   if(g_step <= 0.0)
      return false;
   double s = (price - g_center) / g_step;
   n = (int)MathRound(MathAbs(s));
   side = isBuy ? 0 : 1;
   if(n < 1 || n > g_levels)
      return false;
   return (isBuy ? s > 0.0 : s < 0.0);
  }

bool IsOurOrder()
  {
   return OrderGetString(ORDER_SYMBOL) == _Symbol && (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic;
  }

bool IsOurPosition()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

bool IsOurDeal(const ulong deal)
  {
   return HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol && (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagic;
  }

//+------------------------------------------------------------------+
//| State persistence (survives restarts / timeframe changes)        |
//+------------------------------------------------------------------+
void SaveState()
  {
   GlobalVariableSet(g_gvPrefix + "state", (double)g_state);
   GlobalVariableSet(g_gvPrefix + "center", g_center);
   GlobalVariableSet(g_gvPrefix + "step", g_step);
   GlobalVariableSet(g_gvPrefix + "start", (double)g_cycleStartMsc);
   GlobalVariableSet(g_gvPrefix + "peak", g_peak);
   GlobalVariableSet(g_gvPrefix + "trend", g_trendLatch ? 1.0 : 0.0);
  }

bool LoadState()
  {
   if(!GlobalVariableCheck(g_gvPrefix + "state"))
      return false;
   g_state         = (ENUM_GRID_STATE)(int)GlobalVariableGet(g_gvPrefix + "state");
   g_center        = GlobalVariableGet(g_gvPrefix + "center");
   g_step          = GlobalVariableGet(g_gvPrefix + "step");
   g_cycleStartMsc = (long)GlobalVariableGet(g_gvPrefix + "start");
   g_peak          = GlobalVariableGet(g_gvPrefix + "peak");
   g_trendLatch    = GlobalVariableCheck(g_gvPrefix + "trend") && GlobalVariableGet(g_gvPrefix + "trend") > 0.5;
   return true;
  }

// Counts our orders/positions and returns the earliest one's time.
int CountOurs(long &earliestMsc)
  {
   int count = 0;
   earliestMsc = LONG_MAX;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0 || !IsOurOrder())
         continue;
      count++;
      earliestMsc = MathMin(earliestMsc, OrderGetInteger(ORDER_TIME_SETUP_MSC));
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurPosition())
         continue;
      count++;
      earliestMsc = MathMin(earliestMsc, PositionGetInteger(POSITION_TIME_MSC));
     }
   return count;
  }

// Rebuilds centre and step from one commented order or position.
bool ReconstructGrid()
  {
   double price = 0.0;
   int side = -1, n = 0;
   for(int i = OrdersTotal() - 1; i >= 0 && side < 0; i--)
     {
      if(OrderGetTicket(i) == 0 || !IsOurOrder())
         continue;
      if(ParseComment(OrderGetString(ORDER_COMMENT), side, n))
         price = OrderGetDouble(ORDER_PRICE_OPEN);
      else
         side = -1;
     }
   for(int i = PositionsTotal() - 1; i >= 0 && side < 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurPosition())
         continue;
      if(ParseComment(PositionGetString(POSITION_COMMENT), side, n))
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      else
         side = -1;
     }
   if(side < 0)
      return false;

   double signedN = (side == 0) ? n : -n;
   if(InpStepMode == STEP_PERCENT)
     {
      double center = price / (1.0 + signedN * InpStepPercent / 100.0);
      g_step = NormStep(center * InpStepPercent / 100.0);
     }
   else
      g_step = NormStep(InpStepFixed);
   g_center = price - signedN * g_step;
   return true;
  }

//+------------------------------------------------------------------+
//| Cycle profit                                                     |
//+------------------------------------------------------------------+
long LastOurDealMsc()
  {
   long last = 0;
   if(!HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent() + 86400))
      return 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || !IsOurDeal(deal))
         continue;
      last = MathMax(last, HistoryDealGetInteger(deal, DEAL_TIME_MSC));
     }
   return last;
  }

void RecalcRealized()
  {
   g_realizedDirty    = false;
   g_lastRealizedCalc = GetTickCount64();
   double sum = 0.0;
   datetime from = (datetime)(g_cycleStartMsc / 1000) - 1;
   if(!HistorySelect(from, TimeCurrent() + 86400))
     {
      g_realizedDirty = true;
      return;
     }
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || !IsOurDeal(deal))
         continue;
      if(HistoryDealGetInteger(deal, DEAL_TIME_MSC) < g_cycleStartMsc)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN)
         sum += HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(InpIncludeCosts)
         sum += HistoryDealGetDouble(deal, DEAL_COMMISSION) +
                HistoryDealGetDouble(deal, DEAL_SWAP) +
                HistoryDealGetDouble(deal, DEAL_FEE);
     }
   g_realized = sum;
  }

//+------------------------------------------------------------------+
//| Orders                                                           |
//+------------------------------------------------------------------+
bool PlaceLevel(const int side, const int n, const MqlTick &tick)
  {
   double price = LevelPrice(side, n);
   double stops = StopsDistance();
   if(side == 0 && price <= tick.ask + stops)
      return false;
   if(side == 1 && price >= tick.bid - stops)
      return false;

   int slot = Slot(side, n);
   g_reqTime[slot] = GetTickCount64();
   double lot = NormLot(LevelLot(n));
   bool sent = (side == 0)
               ? g_trade.BuyStop(lot, price, _Symbol, 0.0, 0.0, g_typeTime, 0, LevelComment(side, n))
               : g_trade.SellStop(lot, price, _Symbol, 0.0, 0.0, g_typeTime, 0, LevelComment(side, n));
   if(sent)
      g_placedOnce[slot] = true;
   return sent;
  }

// Async modifies take a moment to show up in POSITION_SL, so the same SL
// must not be sent again while the first request is still in flight.
bool TrailRequestOk(const ulong ticket, const double newSl)
  {
   ulong now = GetTickCount64();
   int size = ArraySize(g_trailTicket);
   for(int i = 0; i < size; i++)
     {
      if(g_trailTicket[i] != ticket)
         continue;
      if(now - g_trailTime[i] < 300)
         return false;
      if(MathAbs(newSl - g_trailSl[i]) < g_tickSize / 2 && now - g_trailTime[i] < 3000)
         return false;
      g_trailTime[i] = now;
      g_trailSl[i]   = newSl;
      return true;
     }
   if(size >= 256)
     {
      ArrayResize(g_trailTicket, 0);
      ArrayResize(g_trailTime, 0);
      ArrayResize(g_trailSl, 0);
      size = 0;
     }
   ArrayResize(g_trailTicket, size + 1);
   ArrayResize(g_trailTime, size + 1);
   ArrayResize(g_trailSl, size + 1);
   g_trailTicket[size] = ticket;
   g_trailTime[size]   = now;
   g_trailSl[size]     = newSl;
   return true;
  }

void TrailPosition(const ulong ticket, const MqlTick &tick)
  {
   long   type  = PositionGetInteger(POSITION_TYPE);
   double open  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double start = InpTrailStartSteps * g_step;
   double dist  = InpTrailDistanceSteps * g_step;
   double move  = MathMax(InpTrailMinMoveSteps * g_step, g_tickSize);
   double stops = StopsDistance();
   double newSl;

   // The original bot trails 2 steps behind price, then 1 step once 3 steps are in profit.
   double profit = (type == POSITION_TYPE_BUY) ? tick.bid - open : open - tick.ask;
   if(InpTrailTightenSteps > 0.0 && profit >= InpTrailTightenSteps * g_step)
      dist = InpTrailTightDistSteps * g_step;

   if(type == POSITION_TYPE_BUY)
     {
      if(tick.bid - open < start)
         return;
      newSl = NormPrice(MathMax(tick.bid - dist, open + InpBreakevenOffset));
      if(tick.bid - newSl < stops)
         return;
      if(sl > 0.0 && newSl < sl + move)
         return;
     }
   else
     {
      if(open - tick.ask < start)
         return;
      newSl = NormPrice(MathMin(tick.ask + dist, open - InpBreakevenOffset));
      if(newSl - tick.ask < stops)
         return;
      if(sl > 0.0 && newSl > sl - move)
         return;
     }

   if(TrailRequestOk(ticket, newSl))
      g_trade.PositionModify(ticket, newSl, 0.0);
  }

//+------------------------------------------------------------------+
//| Cycle control                                                    |
//+------------------------------------------------------------------+
bool IsFridayCutoff()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 6 || dt.day_of_week == 0)
      return true;
   return dt.day_of_week == 5 && dt.hour * 60 + dt.min >= InpFridayHour * 60 + InpFridayMinute;
  }

// True from the daily close time until the pause after it has passed.
bool IsDailyWindow()
  {
   if(!InpDailyClose)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int sinceClose = (dt.hour * 60 + dt.min - (InpDailyHour * 60 + InpDailyMinute) + 1440) % 1440;
   return sinceClose < MathMax(1, InpDailyPauseMin);
  }

void LoadNews()
  {
   g_lastNewsLoad = GetTickCount64();
   ArrayResize(g_newsTimes, 0);
   datetime now = TimeTradeServer();
   string currencies[];
   int count = StringSplit(InpNewsCurrencies, ',', currencies);
   for(int c = 0; c < count; c++)
     {
      string currency = currencies[c];
      StringTrimLeft(currency);
      StringTrimRight(currency);
      if(currency == "")
         continue;
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, now - InpNewsAfterMin * 60, now + 86400, NULL, currency))
        {
         if(g_newsAvailable)
            Print("News filter: economic calendar not available");
         g_newsAvailable = false;
         continue;
        }
      g_newsAvailable = true;
      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event) || event.importance < InpNewsImportance)
            continue;
         int size = ArraySize(g_newsTimes);
         ArrayResize(g_newsTimes, size + 1);
         g_newsTimes[size] = values[i].time;
        }
     }
  }

bool InNewsWindow()
  {
   if(!InpNewsFilter || MQLInfoInteger(MQL_TESTER))
      return false;
   if(g_lastNewsLoad == 0 || GetTickCount64() - g_lastNewsLoad > 600000)
      LoadNews();
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
      if(now >= g_newsTimes[i] - InpNewsBeforeMin * 60 && now <= g_newsTimes[i] + InpNewsAfterMin * 60)
         return true;
   return false;
  }

// Why trend mode may start now ("" = not allowed). Big trends come with news
// and fast markets; in quiet markets a big lot is usually a whipsaw.
string TrendAllowedReason(const bool news)
  {
   if(InpTrendSwitch == TREND_ALWAYS)
      return "always";
   if(news && InpNewsAction == NEWS_TREND)
      return "news";
   if(InpVolSteps > 0.0 && g_step > 0.0)
     {
      double hi[], lo[];
      int bars = MathMax(1, InpVolMinutes);
      if(CopyHigh(_Symbol, PERIOD_M1, 0, bars, hi) == bars && CopyLow(_Symbol, PERIOD_M1, 0, bars, lo) == bars)
        {
         double range = hi[ArrayMaximum(hi)] - lo[ArrayMinimum(lo)];
         if(range >= InpVolSteps * g_step)
            return StringFormat("fast market %.1f steps", range / g_step);
        }
     }
   if(InpTrendUseHours)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      bool inside = (InpTrendStartHour <= InpTrendEndHour)
                    ? (dt.hour >= InpTrendStartHour && dt.hour < InpTrendEndHour)
                    : (dt.hour >= InpTrendStartHour || dt.hour < InpTrendEndHour);
      if(inside)
         return "trend hours";
     }
   return "";
  }

bool CanStartCycle(const MqlTick &tick)
  {
   if(g_paused)
      return false;
   ulong now = GetTickCount64();
   if(now - g_lastStartTry < 1000)
      return false;
   g_lastStartTry = now;

   g_lastBlock = "";
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      g_lastBlock = "market closed";
   else
      if(InpFridayClose && IsFridayCutoff())
         g_lastBlock = "Friday close";
      else
         if(IsDailyWindow())
            g_lastBlock = "daily close pause";
         else
            if(InpNewsAction != NEWS_TREND && InNewsWindow())
               g_lastBlock = "news";
            else
               if(InpMaxSpread > 0.0 && tick.ask - tick.bid > InpMaxSpread)
                  g_lastBlock = StringFormat("spread %.2f", tick.ask - tick.bid);
   if(g_lastBlock == "" && InpUseHours)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      bool inside = (InpStartHour <= InpEndHour)
                    ? (dt.hour >= InpStartHour && dt.hour < InpEndHour)
                    : (dt.hour >= InpStartHour || dt.hour < InpEndHour);
      if(!inside)
         g_lastBlock = "outside hours";
     }
   return g_lastBlock == "";
  }

void StartCycle(const MqlTick &tick)
  {
   double price = tick.bid;
   if(InpCenterPrice == CENTER_ASK)
      price = tick.ask;
   else
      if(InpCenterPrice == CENTER_MID)
         price = (tick.bid + tick.ask) / 2.0;

   g_center = price;
   g_step   = NormStep(InpStepMode == STEP_PERCENT ? price * InpStepPercent / 100.0 : InpStepFixed);
   // Deals of the previous cycle must not count towards this one.
   g_cycleStartMsc   = MathMax(tick.time_msc, LastOurDealMsc()) + 1;
   g_cycleStartLocal = GetTickCount64();
   g_realized        = 0.0;
   g_realizedDirty   = false;
   g_peak            = 0.0;
   g_trendLatch      = false;
   g_trendWhy        = "";
   g_state           = ST_ACTIVE;
   ArrayInitialize(g_placedOnce, false);
   ArrayInitialize(g_reqTime, 0);
   SaveState();

   // Nearest levels first: they are the ones price reaches soonest.
   for(int n = 1; n <= g_levels; n++)
     {
      PlaceLevel(0, n, tick);
      PlaceLevel(1, n, tick);
     }
   PrintFormat("New grid: centre %.2f, step %.2f, %d levels per side", g_center, g_step, g_levels);
  }

void ProcessClosing()
  {
   ulong now = GetTickCount64();
   // Async requests need time to show up; resending too early only produces "invalid request".
   bool resend = (now - g_lastCloseReq >= 3000);
   int orders = 0, positions = 0;

   // Pending orders first, so none of them triggers while positions are being closed.
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurOrder())
         continue;
      orders++;
      if(resend)
         g_trade.OrderDelete(ticket);
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;
      positions++;
      if(resend)
         g_trade.PositionClose(ticket);
     }
   if(resend)
      g_lastCloseReq = now;

   if(orders == 0 && positions == 0)
     {
      g_state = ST_IDLE;
      g_lastStartTry = 0;
      SaveState();
     }
  }

void StartCloseAll(const string reason)
  {
   PrintFormat("Closing grid: %s (cycle profit %.2f)", reason, g_realized + g_lastFloating);
   g_state = ST_CLOSING;
   g_lastCloseReq = 0;
   SaveState();
   ProcessClosing();
  }

void ProcessActive(const MqlTick &tick)
  {
   ulong now = GetTickCount64();
   ArrayInitialize(g_hasOrd, false);
   ArrayInitialize(g_hasPos, false);

   int positions = 0, orders = 0, maxTier = 0;
   double floating = 0.0;
   int side, n;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurPosition())
         continue;
      positions++;
      floating += PositionGetDouble(POSITION_PROFIT);
      if(InpIncludeCosts)
         floating += PositionGetDouble(POSITION_SWAP);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if(LevelOf(isBuy, PositionGetString(POSITION_COMMENT), PositionGetDouble(POSITION_PRICE_OPEN), side, n))
        {
         g_hasPos[Slot(side, n)] = true;
         maxTier = MathMax(maxTier, LevelTier(n));
        }
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0 || !IsOurOrder())
         continue;
      orders++;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;
      if(LevelOf(type == ORDER_TYPE_BUY_STOP, OrderGetString(ORDER_COMMENT), OrderGetDouble(ORDER_PRICE_OPEN), side, n))
         g_hasOrd[Slot(side, n)] = true;
     }

   if(g_realizedDirty || now - g_lastRealizedCalc > 5000)
      RecalcRealized();

   double total = g_realized + floating;
   bool news = InNewsWindow();
   // Once trend mode starts it stays on for the rest of the cycle.
   if(!g_trendLatch && InpTrendEnable && maxTier >= InpTrendTier)
     {
      g_trendWhy = TrendAllowedReason(news);
      if(g_trendWhy != "")
        {
         g_trendLatch = true;
         SaveState();
         PrintFormat("Trend mode on (%s), cycle profit %.2f", g_trendWhy, total);
        }
     }
   bool trend = g_trendLatch;
   g_lastFloating  = floating;
   g_lastPositions = positions;
   g_lastOrders    = orders;
   g_lastTrend     = trend;

   // Grid removed from outside (manually or by the broker): start over.
   if(positions == 0 && orders == 0 && now - g_cycleStartLocal > 5000)
     {
      g_state = ST_IDLE;
      SaveState();
      return;
     }

   if(InpFridayClose && IsFridayCutoff())
     {
      StartCloseAll("Friday close");
      return;
     }
   if(IsDailyWindow())
     {
      StartCloseAll("daily close");
      return;
     }
   if(news && InpNewsAction == NEWS_CLOSE_ALL)
     {
      StartCloseAll("news");
      return;
     }
   bool newsHold = news && InpNewsAction == NEWS_DELETE_PENDING;
   g_lastBlock = newsHold ? "news: pending removed" : "";
   if(newsHold && orders > 0 && now - g_lastNewsDelete >= 3000)
     {
      g_lastNewsDelete = now;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket != 0 && IsOurOrder())
            g_trade.OrderDelete(ticket);
        }
     }
   if(InpMaxLoss > 0.0 && total <= -InpMaxLoss)
     {
      if(InpPauseAfterMaxLoss)
         g_paused = true;
      StartCloseAll("max loss");
      return;
     }
   if(trend)
     {
      if(total >= InpTrendTarget)
         g_peak = MathMax(g_peak, total);
      if(g_peak > 0.0 && total <= g_peak * (1.0 - InpTrendGivebackPct / 100.0))
        {
         StartCloseAll("trend giveback");
         return;
        }
     }
   else
     {
      g_peak = 0.0;
      if(total >= InpBasketTarget)
        {
         StartCloseAll("basket target");
         return;
        }
     }

   if(InpTrailEnable && !(trend && InpTrendNoTrail))
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOurPosition())
            continue;
         TrailPosition(ticket, tick);
        }
     }

   if(newsHold)
      return;
   for(int s = 0; s <= 1; s++)
      for(int lvl = 1; lvl <= g_levels; lvl++)
        {
         int slot = Slot(s, lvl);
         if(g_hasOrd[slot] || g_hasPos[slot])
            continue;
         if(!InpReplaceLevels && g_placedOnce[slot])
            continue;
         if(now - g_reqTime[slot] < 2000)
            continue;
         PlaceLevel(s, lvl, tick);
        }
  }

// Cent accounts report balance in cents: USC (Exness), USc, UScent and similar.
bool IsCentAccount()
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   StringToUpper(cur);
   return cur == "USC" || StringFind(cur, "CENT") >= 0;
  }

void UpdatePanel()
  {
   if(!InpShowPanel)
      return;
   ulong now = GetTickCount64();
   if(now - g_lastPanel < 500)
      return;
   g_lastPanel = now;

   string state = (g_state == ST_ACTIVE) ? "ACTIVE" : (g_state == ST_CLOSING ? "CLOSING" : "IDLE");
   if(g_paused)
      state += " (PAUSED)";
   double total = g_realized + g_lastFloating;
   string money = AccountInfoString(ACCOUNT_CURRENCY);
   if(IsCentAccount())
      money += StringFormat(" (= $%.2f)", total / 100.0);
   Comment(StringFormat(GSE_NAME + "  |  %s\n"
                        "Centre: %.2f   Step: %.2f   Levels/side: %d\n"
                        "Positions: %d   Pending: %d\n"
                        "Closed: %.2f   Floating: %.2f\n"
                        "Cycle profit: %.2f %s / %s\n"
                        "%s",
                        state, g_center, g_step, g_levels,
                        g_lastPositions, g_lastOrders,
                        g_realized, g_lastFloating,
                        total, money,
                        g_lastTrend ? StringFormat("trend, %s (peak %.2f)", g_trendWhy, g_peak) : DoubleToString(InpBasketTarget, 2),
                        g_lastBlock == "" ? "" : "Waiting: " + g_lastBlock));
  }

void Process()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      UpdatePanel();
      return;
     }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0)
      return;

   if(g_state == ST_CLOSING)
      ProcessClosing();
   if(g_state == ST_IDLE)
     {
      if(CanStartCycle(tick))
         StartCycle(tick);
     }
   else
      if(g_state == ST_ACTIVE)
         ProcessActive(tick);
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpTier1Levels < 0 || InpTier2Levels < 0 || InpTier3Levels < 0 ||
      InpTier1Levels + InpTier2Levels + InpTier3Levels <= 0 ||
      (InpStepMode == STEP_PERCENT && InpStepPercent <= 0.0) ||
      (InpStepMode == STEP_FIXED && InpStepFixed <= 0.0) ||
      InpBasketTarget <= 0.0)
     {
      Print("Invalid inputs: check levels, step and basket target");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = _Point;
   g_levels   = InpTier1Levels + InpTier2Levels + InpTier3Levels;
   g_gvPrefix = StringFormat("GSE_%s_%I64u_", _Symbol, InpMagic);

   ArrayResize(g_hasOrd, 2 * g_levels);
   ArrayResize(g_hasPos, 2 * g_levels);
   ArrayResize(g_placedOnce, 2 * g_levels);
   ArrayResize(g_reqTime, 2 * g_levels);
   ArrayInitialize(g_placedOnce, true); // restored grid: do not re-place unless allowed
   ArrayInitialize(g_reqTime, 0);

   int expiration = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   g_typeTime = ((expiration & SYMBOL_EXPIRATION_GTC) != 0) ? ORDER_TIME_GTC : ORDER_TIME_DAY;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((ulong)MathRound(InpMaxSlippage / _Point));
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(InpAsync);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   long limit = AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
   if(limit > 0 && limit < 2 * g_levels)
      PrintFormat("Warning: broker allows %d pending orders, grid needs %d", limit, 2 * g_levels);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Warning: this EA needs a HEDGING account");
#ifdef GSE_CENT
   if(!IsCentAccount())
      PrintFormat("Warning: account currency is %s, not a cent account. Use GridStopEA instead", AccountInfoString(ACCOUNT_CURRENCY));
#else
#ifdef GSE_BTC
   if(StringFind(_Symbol, "BTC") < 0)
      PrintFormat("Warning: %s is not a BTC symbol. GridStopEA_BTC defaults are sized for BTCUSD", _Symbol);
#endif
   if(IsCentAccount())
      Print("Warning: cent account detected. Money inputs (target, max loss) are read as cents; GridStopEA_Cent has cent defaults");
#endif

   // Resume a grid that is already running.
   long earliest;
   int ours = CountOurs(earliest);
   bool loaded = LoadState();
   if(ours == 0)
     {
      g_state = ST_IDLE;
     }
   else
      if(!loaded || g_state == ST_IDLE || g_step <= 0.0)
        {
         if(ReconstructGrid())
           {
            g_state = ST_ACTIVE;
            g_cycleStartMsc = earliest;
            g_peak = 0.0;
            SaveState();
            Print("Existing grid restored from orders");
           }
         else
           {
            g_paused = true;
            Alert(GSE_NAME + ": found orders with this magic but cannot read the grid. Close them manually.");
           }
        }
   g_cycleStartLocal = GetTickCount64();
   g_realizedDirty = true;

   EventSetMillisecondTimer(MathMax(10, InpTimerMs));
   Process();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveState();
   Comment("");
  }

void OnTick()
  {
   Process();
  }

void OnTimer()
  {
   Process();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_realizedDirty = true;
  }
//+------------------------------------------------------------------+
