//+------------------------------------------------------------------+
//| Timed SL Remover EA v3.0 - 3-mode SL handling                    |
//|  1) Remove SL completely                                         |
//|  2) Move SL far away from entry (broker-safe)                    |
//|  3) Risk-percentage based SL (funded-account drawdown guard)     |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_SL_MODE
{
   SL_MODE_REMOVE,     // 0 - Remove SL completely
   SL_MODE_FAR_AWAY,   // 1 - Move SL far away from entry
   SL_MODE_RISK_PCT    // 2 - Set SL based on max risk % of account
};

input string   Start              = "23:50";
input string   End                = "01:15";
input ENUM_SL_MODE SLMode         = SL_MODE_REMOVE;    // SL handling mode
input double   Mode2_FarAwayPips  = 10000;             // Mode 2: Pips away from entry (0 = broker min)
input double   Mode3_RiskPercent  = 2.0;             // Mode 3: Max loss % of account balance
input string   SaveFileName       = "SLRemoverEALogs.csv"; // MQL5\Files\SLRemoverEALogs.csv

struct SLRecord
{
   int       entryId;       // #ENTRY shown in CSV
   ulong     ticket;
   string    symbol;
   double    originalSL;

   bool      removed;
   datetime  removedTime;
   bool      restored;
   datetime  restoredTime;

   int       rowIndex;      // 1-based row index (excl. header) for updating
};

SLRecord records[];
bool restoredForThisWindow = false;
int  entryCounter = 0;

//------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------
int TimeOfDaySeconds(string t)
{
   return (int)StringToInteger(StringSubstr(t,0,2)) * 3600
        + (int)StringToInteger(StringSubstr(t,3,2)) * 60;
}

int NowOfDaySeconds()
{
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   return dt.hour*3600 + dt.min*60 + dt.sec;
}

bool InWindow(int startSec, int endSec)
{
   int nowSec = NowOfDaySeconds();
   if(startSec <= endSec) return nowSec >= startSec && nowSec < endSec;
   return (nowSec >= startSec || nowSec < endSec);
}

string DtStr(datetime t)
{
   return (t>0) ? TimeToString(t, TIME_MINUTES) + " (BROKER)" : "";
}

//------------------------------------------------------------------
// Pip helpers
//------------------------------------------------------------------
double PipsToPrice(string sym, double pips)
{
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3) return pips * point * 10.0;
   return pips * point;
}

//------------------------------------------------------------------
// Risk-based SL calculator
//------------------------------------------------------------------
double CalculateRiskBasedSL(string sym, ENUM_POSITION_TYPE posType)
{
   double volume    = PositionGetDouble(POSITION_VOLUME);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(sym, SYMBOL_POINT);

   if(tickSize <= 0 || point <= 0 || volume <= 0) return 0;

   double valuePerPoint = volume * tickValue * point / tickSize;
   if(valuePerPoint <= 0) return 0;

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount     = accountBalance * Mode3_RiskPercent / 100.0;

   double currentPnL     = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   double remainingRisk  = riskAmount + currentPnL;

   if(remainingRisk <= 0) return 0; // already past the max risk limit

   double distancePoints = remainingRisk / valuePerPoint;
   double currentPrice   = (posType == POSITION_TYPE_BUY)
                           ? SymbolInfoDouble(sym, SYMBOL_BID)
                           : SymbolInfoDouble(sym, SYMBOL_ASK);

   double sl = 0.0;
   if(posType == POSITION_TYPE_BUY)
      sl = currentPrice - distancePoints * point;
   else
      sl = currentPrice + distancePoints * point;

   // Enforce broker stops level
   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist  = stopsLevel * point;

   if(posType == POSITION_TYPE_BUY)
   {
      double maxSL = currentPrice - minDist;
      if(sl > maxSL) sl = maxSL;
   }
   else
   {
      double minSL = currentPrice + minDist;
      if(sl < minSL) sl = minSL;
   }

   return NormalizeDouble(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
}

//------------------------------------------------------------------
// CSV helpers
//------------------------------------------------------------------

// Count existing data rows (excludes the header line)
int CountExistingRows()
{
   if(!FileIsExist(SaveFileName)) return 0;

   int h = FileOpen(SaveFileName, FILE_READ|FILE_CSV|FILE_ANSI, ';');
   if(h==INVALID_HANDLE) return 0;

   int rows = 0;
   if(!FileIsEnding(h))
   {
      string first = FileReadString(h);
      if(first == "#ENTRY")
      {
         for(int k=0; k<5 && !FileIsEnding(h); k++) FileReadString(h);
      }
      else
      {
         FileSeek(h, 0, SEEK_SET);
      }
   }

   while(!FileIsEnding(h))
   {
      string c0 = FileReadString(h);
      if(FileIsEnding(h)) break;
      for(int k=0; k<5 && !FileIsEnding(h); k++) FileReadString(h);
      rows++;
   }

   FileClose(h);
   return rows;
}

// Read the whole CSV into memory as lines of "f1;f2;...;f6"
void ReadWholeCsv(string &content[], int &lines)
{
   ArrayResize(content, 0);
   lines = 0;

   if(!FileIsExist(SaveFileName))
      return;

   int h = FileOpen(SaveFileName, FILE_READ|FILE_CSV|FILE_ANSI, ';');
   if(h==INVALID_HANDLE)
      return;

   while(!FileIsEnding(h))
   {
      string row = "";
      for(int k=0; k<6 && !FileIsEnding(h); k++)
      {
         if(k>0) row += ";";
         row += FileReadString(h);
      }
      if(row != "")
      {
         ArrayResize(content, lines+1);
         content[lines] = row;
         lines++;
      }
   }

   FileClose(h);
}

// Write out all lines (already semicolon-joined) to CSV
void WriteWholeCsv(string &content[], int lines)
{
   int h = FileOpen(SaveFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
   if(h==INVALID_HANDLE)
   {
      Print("File open failed for write, Err=", GetLastError());
      return;
   }

   for(int i=0; i<lines; i++)
   {
      string fields[];
      int cnt = StringSplit(content[i], ';', fields);
      if(cnt>0)
      {
         FileWrite(h,
                   fields[0],
                   (cnt>1?fields[1]:""),
                   (cnt>2?fields[2]:""),
                   (cnt>3?fields[3]:""),
                   (cnt>4?fields[4]:""),
                   (cnt>5?fields[5]:""));
      }
   }
   FileClose(h);
}

// Append a new row for the removal event, safely (no read+write open)
int AppendLogRow(SLRecord &r)
{
   string content[];
   int lines = 0;
   ReadWholeCsv(content, lines);

   if(lines == 0)
   {
      ArrayResize(content, 1);
      content[0] = "#ENTRY;PAIR;SL Removed;SL Removed Time;SL Restored;SL Restored Time";
      lines = 1;
   }

   int entryNo = CountExistingRows() + 1;

   string newRow = StringFormat("#%d;%s;%s;%s;%s;%s",
                                entryNo,
                                r.symbol,
                                (r.removed ? "YES" : "NO"),
                                DtStr(r.removedTime),
                                (r.restored ? "YES" : "NO"),
                                DtStr(r.restoredTime));

   ArrayResize(content, lines+1);
   content[lines] = newRow;
   lines++;

   WriteWholeCsv(content, lines);

   r.entryId  = entryNo;
   r.rowIndex = entryNo;
   return r.rowIndex;
}

// Update an existing row (flip restored to YES & time)
void UpdateLogRow(const SLRecord &r)
{
   if(r.rowIndex <= 0) return;

   string content[];
   int lines = 0;
   ReadWholeCsv(content, lines);
   if(lines == 0) return;
   if(r.rowIndex >= lines) return;

   content[r.rowIndex] = StringFormat("#%d;%s;%s;%s;%s;%s",
                                      r.entryId,
                                      r.symbol,
                                      (r.removed  ? "YES" : "NO"),
                                      DtStr(r.removedTime),
                                      (r.restored ? "YES" : "NO"),
                                      DtStr(r.restoredTime));

   WriteWholeCsv(content, lines);
}

//------------------------------------------------------------------
// Records
//------------------------------------------------------------------
int FindRecordIndexByTicket(ulong ticket)
{
   for(int i=0;i<ArraySize(records);i++)
      if(records[i].ticket==ticket) return i;
   return -1;
}

int EnsureRecord(ulong ticket,string sym,double originalSL)
{
   int idx=FindRecordIndexByTicket(ticket);
   if(idx>=0) return idx;

   SLRecord r;
   r.entryId=0;
   r.ticket=ticket;
   r.symbol=sym;
   r.originalSL=originalSL;
   r.removed=false;
   r.removedTime=0;
   r.restored=false;
   r.restoredTime=0;
   r.rowIndex=-1;

   int n=ArraySize(records); ArrayResize(records,n+1); records[n]=r;
   return n;
}

//------------------------------------------------------------------
// Actions
//------------------------------------------------------------------
void EnsureSLAdjustedForPosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   string sym = PositionGetString(POSITION_SYMBOL);
   double currentSL = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   int idx = EnsureRecord(ticket, sym, currentSL);
   if(records[idx].removed) return; // already acted this session

   double targetSL = 0.0;
   string actionDesc = "";
   bool needModify = false;

   switch(SLMode)
   {
      case SL_MODE_REMOVE:
         targetSL = 0.0;
         actionDesc = "Removed SL";
         if(currentSL == 0.0) return;
         needModify = true;
         break;

      case SL_MODE_FAR_AWAY:
         {
            double dist = PipsToPrice(sym, Mode2_FarAwayPips);
            if(posType == POSITION_TYPE_BUY)
               targetSL = entryPrice - dist;
            else
               targetSL = entryPrice + dist;

            // Clamp to broker minimum distance from current price
            long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
            double minDist  = stopsLevel * SymbolInfoDouble(sym, SYMBOL_POINT);
            double currentPrice = (posType == POSITION_TYPE_BUY)
                                  ? SymbolInfoDouble(sym, SYMBOL_BID)
                                  : SymbolInfoDouble(sym, SYMBOL_ASK);

            if(posType == POSITION_TYPE_BUY)
            {
               double maxAllowedSL = currentPrice - minDist;
               if(targetSL > maxAllowedSL) targetSL = maxAllowedSL;
            }
            else
            {
               double minAllowedSL = currentPrice + minDist;
               if(targetSL < minAllowedSL) targetSL = minAllowedSL;
            }

            targetSL = NormalizeDouble(targetSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
            actionDesc = "Moved SL far away";

            // Don't move SL closer (increase risk) if already farther away
            if(currentSL != 0.0)
            {
               if(posType == POSITION_TYPE_BUY && currentSL < targetSL) return;
               if(posType == POSITION_TYPE_SELL && currentSL > targetSL) return;
            }
            needModify = true;
         }
         break;

      case SL_MODE_RISK_PCT:
         {
            targetSL = CalculateRiskBasedSL(sym, posType);
            if(targetSL <= 0.0)
            {
               PrintFormat("Risk-based SL calc failed or over limit for %s ticket=%I64u", sym, ticket);
               return;
            }
            actionDesc = "Set risk-based SL";

            // Don't move SL to a worse (more risky) level if current is already tighter
            if(currentSL != 0.0)
            {
               if(posType == POSITION_TYPE_BUY && currentSL > targetSL) return;
               if(posType == POSITION_TYPE_SELL && currentSL < targetSL) return;
            }
            needModify = true;
         }
         break;
   }

   if(!needModify) return;

   if(trade.PositionModify(ticket, targetSL, tp))
   {
      PrintFormat("%s for %s ticket=%I64u targetSL=%s", actionDesc, sym, ticket,
                  DoubleToString(targetSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
      records[idx].removed = true;
      records[idx].removedTime = TimeCurrent();
      records[idx].rowIndex = AppendLogRow(records[idx]);
   }
   else
   {
      PrintFormat("FAILED %s for %s ticket=%I64u err=%d", actionDesc, sym, ticket, GetLastError());
   }
}

void RestoreSavedSLs()
{
   for(int i=0;i<ArraySize(records);i++)
   {
      if(records[i].restored) continue;

      ulong t = records[i].ticket;
      if(!PositionSelectByTicket(t))
      {
         PrintFormat("Position closed before restore, ticket=%I64u", t);
         records[i].restored = true; // nothing to restore
         UpdateLogRow(records[i]);
         continue;
      }

      string sym = PositionGetString(POSITION_SYMBOL);
      double tp  = PositionGetDouble(POSITION_TP);
      double originalSL = records[i].originalSL;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double currentPrice = (posType == POSITION_TYPE_BUY)
                            ? SymbolInfoDouble(sym, SYMBOL_BID)
                            : SymbolInfoDouble(sym, SYMBOL_ASK);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist  = stopsLevel * point;
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

      double safeSL = originalSL;
      bool canRestore = true;

      // If original SL was 0 (no SL), we can always restore to 0
      if(originalSL != 0.0)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            // SL must be below current price, otherwise immediate trigger
            if(originalSL >= currentPrice - minDist)
            {
               PrintFormat("SKIP restore for %s ticket=%I64u: originalSL=%s >= currentPrice=%s (would trigger immediately)",
                           sym, t,
                           DoubleToString(originalSL, digits),
                           DoubleToString(currentPrice, digits));
               canRestore = false;
            }
         }
         else // SELL
         {
            // SL must be above current price, otherwise immediate trigger
            if(originalSL <= currentPrice + minDist)
            {
               PrintFormat("SKIP restore for %s ticket=%I64u: originalSL=%s <= currentPrice=%s (would trigger immediately)",
                           sym, t,
                           DoubleToString(originalSL, digits),
                           DoubleToString(currentPrice, digits));
               canRestore = false;
            }
         }
      }

      if(!canRestore)
      {
         // Mark as restored (skipped) so we don't try again every tick
         records[i].restored = true;
         records[i].restoredTime = TimeCurrent();
         UpdateLogRow(records[i]);
         continue;
      }

      if(trade.PositionModify(t, safeSL, tp))
      {
         PrintFormat("Restored SL for %s ticket=%I64u SL=%s", sym, t,
                     (safeSL > 0 ? DoubleToString(safeSL, digits) : "NONE"));
         records[i].restored     = true;
         records[i].restoredTime = TimeCurrent();
      }
      else
      {
         PrintFormat("FAILED restore SL for %s ticket=%I64u err=%d", sym, t, GetLastError());
      }

      UpdateLogRow(records[i]);
   }
}

//------------------------------------------------------------------
// EA lifecycle
//------------------------------------------------------------------
int OnInit()
{
   Print("EA init. Start=",Start," End=",End," Mode=",EnumToString(SLMode));
   restoredForThisWindow=false;
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){ EventKillTimer(); }

//------------------------------------------------------------------
// Main loop
//------------------------------------------------------------------
void OnTimer()
{
   const int s=TimeOfDaySeconds(Start), e=TimeOfDaySeconds(End), n=NowOfDaySeconds();
   bool inside=(s<=e)?(n>=s&&n<e):(n>=s||n<e);

   if(inside)
   {
      restoredForThisWindow=false;
      int total=PositionsTotal();
      for(int i=0;i<total;i++)
      {
         ulong t=PositionGetTicket(i);
         if(t==0) continue;
         if(!PositionSelectByTicket(t)) continue;
         EnsureSLAdjustedForPosition(t);
      }
   }
   else if(!restoredForThisWindow)
   {
      RestoreSavedSLs();
      restoredForThisWindow=true;
   }
}
