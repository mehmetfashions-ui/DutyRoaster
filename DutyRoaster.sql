/* =========
   0) Active Ops users view (Users only)
   ========= */
CREATE OR ALTER VIEW dbo.vw_ActiveOpsUsers AS
SELECT
  u.UserID,
  CAST(u.StaffID AS nchar(10))         AS StaffID,
  LTRIM(RTRIM(COALESCE(u.FullName,u.UserName))) AS FullName,
  u.Team,
  CAST(ISNULL(u.Activated,1) AS bit)   AS IsActive,
  u.EMail
FROM dbo.Users u
WHERE (u.Team = N'Operations' OR u.Team IS NULL)
  AND (u.Activated = 1 OR u.Activated IS NULL);

/* =========
   1) Shifts
   ========= */
CREATE TABLE dbo.ShiftCategory (
  CategoryID   int IDENTITY(1,1) PRIMARY KEY,
  CategoryName varchar(50) NOT NULL UNIQUE  -- BCNOC / Playout / General
);

CREATE TABLE dbo.ShiftTemplate (
  ShiftID       int IDENTITY(1,1) PRIMARY KEY,
  ShiftName     varchar(100) NOT NULL,   -- '08:00–20:00_BCNOC'
  CategoryID    int          NOT NULL REFERENCES dbo.ShiftCategory(CategoryID),
  StartTime     time(0)      NOT NULL,
  EndTime       time(0)      NOT NULL,
  LengthHours   tinyint      NOT NULL,
  Priority      tinyint      NOT NULL,   -- 1=General, 2=Morning, 3=Night
  RequiredCount tinyint      NOT NULL,
  IsCore        bit          NOT NULL DEFAULT(1)
);

INSERT INTO dbo.ShiftCategory(CategoryName) VALUES ('BCNOC'),('Playout'),('General');

INSERT INTO dbo.ShiftTemplate(ShiftName,CategoryID,StartTime,EndTime,LengthHours,Priority,RequiredCount,IsCore)
SELECT '08:00–20:00_BCNOC', c.CategoryID, '08:00','20:00',12,2,2,1 FROM dbo.ShiftCategory c WHERE c.CategoryName='BCNOC'
UNION ALL
SELECT '08:00–20:00_PLAYOUT', c.CategoryID, '08:00','20:00',12,2,2,1 FROM dbo.ShiftCategory c WHERE c.CategoryName='Playout'
UNION ALL
SELECT '20:00–08:00_BCNOC', c.CategoryID, '20:00','08:00',12,3,2,1 FROM dbo.ShiftCategory c WHERE c.CategoryName='BCNOC'
UNION ALL
SELECT '20:00–08:00_PLAYOUT', c.CategoryID, '20:00','08:00',12,3,2,1 FROM dbo.ShiftCategory c WHERE c.CategoryName='Playout'
UNION ALL
SELECT '08:00–20:00_GENERAL', c.CategoryID, '08:00','20:00',12,1,1,0 FROM dbo.ShiftCategory c WHERE c.CategoryName='General';

/* =========
   2) Periods
   ========= */
CREATE TABLE dbo.RosterPeriod (
  RosterPeriodID int IDENTITY(1,1) PRIMARY KEY,
  PeriodName     varchar(100) NOT NULL,
  StartDate      date         NOT NULL,  -- Monday (Week 1)
  EndDate        date         NOT NULL,  -- Sunday (Week 2)
  Weeks          tinyint      NOT NULL DEFAULT(2),
  Status         varchar(20)  NOT NULL DEFAULT('Open') -- Open/Locked/Archived
);
ALTER TABLE dbo.RosterPeriod WITH CHECK
ADD CONSTRAINT CK_RosterPeriod_14Days CHECK (DATEDIFF(DAY, StartDate, EndDate) = 13);

/* =========
   3) Per-user settings (effective-dated)
   ========= */
CREATE TABLE dbo.UserSettings (
  UserID        numeric(18,0) NOT NULL REFERENCES dbo.Users(UserID),
  EffectiveFrom date          NOT NULL,
  WeeklyHours   tinyint       NOT NULL CONSTRAINT DF_UserSettings_Weekly DEFAULT(48),
  MorningRatio  tinyint       NOT NULL CONSTRAINT DF_UserSettings_Morn DEFAULT(2),
  NightRatio    tinyint       NOT NULL CONSTRAINT DF_UserSettings_Night DEFAULT(2),
  RatingsJson   nvarchar(max) NULL,  -- {"BCNOC":4,"Playout":3,"General":2}
  CONSTRAINT PK_UserSettings PRIMARY KEY (UserID, EffectiveFrom),
  CONSTRAINT CK_UserSettings_IsJson CHECK (RatingsJson IS NULL OR ISJSON(RatingsJson)=1),
  CONSTRAINT CK_UserSettings_Ratios CHECK (
    MorningRatio BETWEEN 0 AND 10 AND NightRatio BETWEEN 0 AND 10 AND (MorningRatio+NightRatio)>0
  ),
  CONSTRAINT CK_UserSettings_Weekly CHECK (WeeklyHours BETWEEN 1 AND 84)
);

ALTER TABLE dbo.UserSettings
ADD BCNOC_Rating   AS TRY_CONVERT(tinyint, JSON_VALUE(RatingsJson, '$.BCNOC')) PERSISTED,
    Playout_Rating AS TRY_CONVERT(tinyint, JSON_VALUE(RatingsJson, '$.Playout')) PERSISTED,
    General_Rating AS TRY_CONVERT(tinyint, JSON_VALUE(RatingsJson, '$.General')) PERSISTED;

ALTER TABLE dbo.UserSettings
ADD CONSTRAINT CK_UserSettings_BCNOC   CHECK (BCNOC_Rating   IS NULL OR BCNOC_Rating   BETWEEN 1 AND 5),
    CONSTRAINT CK_UserSettings_Playout CHECK (Playout_Rating IS NULL OR Playout_Rating BETWEEN 1 AND 5),
    CONSTRAINT CK_UserSettings_General CHECK (General_Rating IS NULL OR General_Rating BETWEEN 1 AND 5);

/* =========
   4) Daily preferences
   ========= */
CREATE TABLE dbo.UserDailyPreference (
  UserID     numeric(18,0) NOT NULL REFERENCES dbo.Users(UserID),
  PrefDate   date          NOT NULL,
  PrefMorning bit          NOT NULL DEFAULT(0),
  PrefNight   bit          NOT NULL DEFAULT(0),
  PrefOff     bit          NOT NULL DEFAULT(0),
  PrefLeave   bit          NOT NULL DEFAULT(0),
  CONSTRAINT PK_UserDailyPreference PRIMARY KEY (UserID, PrefDate),
  CONSTRAINT CK_UserDailyPref_LeaveExcludesOthers CHECK (
     (PrefLeave=1 AND PrefMorning=0 AND PrefNight=0 AND PrefOff=0) OR (PrefLeave=0)
  )
);

/* =========
   5) Conflicts & special group (night cap)
   ========= */
CREATE TABLE dbo.UserConflictPair (
  UserID_A numeric(18,0) NOT NULL REFERENCES dbo.Users(UserID),
  UserID_B numeric(18,0) NOT NULL REFERENCES dbo.Users(UserID),
  CONSTRAINT PK_UserConflictPair PRIMARY KEY (UserID_A, UserID_B),
  CONSTRAINT CK_UserConflictPair_Order CHECK (UserID_A < UserID_B)
);

CREATE TABLE dbo.SpecialGroup (
  GroupID   int IDENTITY(1,1) PRIMARY KEY,
  GroupName varchar(100) NOT NULL UNIQUE
);
CREATE TABLE dbo.SpecialGroupMember (
  GroupID int            NOT NULL REFERENCES dbo.SpecialGroup(GroupID),
  UserID  numeric(18,0)  NOT NULL REFERENCES dbo.Users(UserID),
  CONSTRAINT PK_SpecialGroupMember PRIMARY KEY (GroupID, UserID)
);

/* =========
   6) Roster assignments (keyed by UserID)
   ========= */
CREATE TABLE dbo.RosterAssignment (
  RosterAssignmentID bigint       IDENTITY(1,1) PRIMARY KEY,
  RosterPeriodID     int          NOT NULL REFERENCES dbo.RosterPeriod(RosterPeriodID),
  WorkDate           date         NOT NULL,
  ShiftID            int          NOT NULL REFERENCES dbo.ShiftTemplate(ShiftID),
  UserID             numeric(18,0) NOT NULL REFERENCES dbo.Users(UserID),
  CreatedAt          datetime2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
  CreatedBy          nvarchar(100) NULL
);
CREATE UNIQUE INDEX UX_RosterAssignment_UserDate ON dbo.RosterAssignment (UserID, WorkDate);
CREATE INDEX IX_RosterAssignment_PeriodDateShift ON dbo.RosterAssignment (RosterPeriodID, WorkDate, ShiftID);

/* =========
   7) Trigger: block Morning after previous Night
   ========= */
GO
CREATE OR ALTER TRIGGER dbo.TR_RosterAssignment_BlockMorningAfterNight
ON dbo.RosterAssignment
AFTER INSERT, UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  ;WITH NightShifts AS (SELECT ShiftID FROM dbo.ShiftTemplate WHERE Priority=3),
       MorningShifts AS (SELECT ShiftID FROM dbo.ShiftTemplate WHERE Priority=2),
       Violations AS (
         SELECT i.*
         FROM inserted i
         JOIN MorningShifts ms ON ms.ShiftID = i.ShiftID
         JOIN dbo.RosterAssignment prev
               ON prev.UserID = i.UserID
              AND prev.WorkDate = DATEADD(DAY,-1,i.WorkDate)
         JOIN NightShifts ns ON ns.ShiftID = prev.ShiftID
       )
  IF EXISTS (SELECT 1 FROM Violations)
  BEGIN
     RAISERROR('Cannot assign Morning immediately after last night''s Night shift for the same user.',16,1);
     ROLLBACK TRANSACTION; RETURN;
  END
END
GO

/* =========
   8) Summary view (UserID keyed; display StaffID)
   ========= */
CREATE OR ALTER VIEW dbo.vw_RosterSummary AS
WITH PeriodDays AS (
  SELECT rp.RosterPeriodID, rp.StartDate,
         DATEADD(DAY,6, rp.StartDate) AS Week1End,
         DATEADD(DAY,7, rp.StartDate) AS Week2Start,
         rp.EndDate AS Week2End
  FROM dbo.RosterPeriod rp
),
Base AS (
  SELECT ra.UserID,
         u.StaffID,
         v.FullName,
         ra.RosterPeriodID,
         ra.WorkDate,
         st.LengthHours,
         CASE WHEN ra.WorkDate BETWEEN pd.StartDate AND pd.Week1End THEN 'Week 1' ELSE 'Week 2' END AS WeekName
  FROM dbo.RosterAssignment ra
  JOIN dbo.ShiftTemplate st ON st.ShiftID = ra.ShiftID
  JOIN dbo.vw_ActiveOpsUsers v ON v.UserID = ra.UserID
  JOIN dbo.Users u ON u.UserID = ra.UserID
  JOIN PeriodDays pd ON pd.RosterPeriodID = ra.RosterPeriodID
)
SELECT
  b.RosterPeriodID,
  b.UserID,
  MAX(b.StaffID)  AS StaffID,
  MAX(b.FullName) AS FullName,
  SUM(CASE WHEN b.WeekName='Week 1' THEN b.LengthHours ELSE 0 END) AS Week1Hours,
  SUM(CASE WHEN b.WeekName='Week 2' THEN b.LengthHours ELSE 0 END) AS Week2Hours,
  SUM(b.LengthHours) AS TotalHours,
  SUM(CASE WHEN b.WeekName='Week 1' THEN 1 ELSE 0 END) AS Week1WorkDays,
  SUM(CASE WHEN b.WeekName='Week 2' THEN 1 ELSE 0 END) AS Week2WorkDays
FROM Base b
GROUP BY b.RosterPeriodID, b.UserID;
