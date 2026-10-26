 Widget _miniStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _titleColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _dayRow(DailyRecord r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _isDark
            ? AppColors.slate800.withValues(alpha: 0.5)
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dayLabel(r.date),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _titleColor,
                  ),
                ),
              ),
              Icon(
                r.isPerfect ? Icons.star_rounded : Icons.star_border_rounded,
                size: 16,
                color: r.isPerfect ? Colors.amber.shade600 : _mutedColor,
              ),
              const SizedBox(width: 4),
              Text(
                '${r.habitsDone}/3 habits',
                style: TextStyle(fontSize: 11, color: _mutedColor),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '💧 ${(r.water / 1000).toStringAsFixed(1)} / ${(r.waterGoal / 1000).toStringAsFixed(1)} L'
            '   ·   👣 ${_thousands(r.steps)} steps',
            style: TextStyle(fontSize: 12, color: _bodyColor),
          ),
        ],
      ),
    );
  }

  // --- Sections --------------------------------------------------------------

  Widget _buildInsightCard(int activeDays, double? stepsNow, double? stepsPrev) {
    final pct = _pctChange(stepsNow, stepsPrev);
    String emoji;
    String text;

    if (activeDays < 2) {
      emoji = '🌱';
      text = 'Your journey starts here! Log your water, steps and habits each '
          'day — your progress will build up on this page.';
    } else if (pct != null) {
      final rounded = pct.round();
      if (rounded >= 5) {
        emoji = '🎉';
        text = 'Great work! You walked $rounded% more per day than the week before.';
      } else if (rounded <= -5) {
        emoji = '💪';
        text = 'Your steps dipped ${rounded.abs()}% compared with the week before. '
            'A few extra walks and you will be right back on track.';
      } else {
        emoji = '👍';
        text = 'Steady and consistent — your activity is about the same as the week before.';
      }
    } else {
      emoji = '📈';
      text = 'You have logged $activeDays days so far. Keep going — once you '
          'have a second week of steps, you will see exactly how much you improved.';
    }

    return _card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 32)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: _titleColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeeklyCard(
    double? stepsNow,
    double? stepsPrev,
    double? waterNow,
    double? waterPrev,
  ) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.trending_up, 'Weekly comparison'),
          const SizedBox(height: 4),
          Text(
            'Last 7 days compared with the 7 days before (today not counted — it is still in progress).',
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
          const SizedBox(height: 14),
          _compareRow(
            icon: Icons.directions_walk,
            color: _p.primaryColor,
            label: 'Steps',
            now: stepsNow,
            prev: stepsPrev,
            format: (v) => _thousands(v.round()),
          ),
          const SizedBox(height: 14),
          _compareRow(
            icon: Icons.water_drop,
            color: Colors.cyan,
            label: 'Water',
            now: waterNow,
            prev: waterPrev,
            format: (v) => '${(v / 1000).toStringAsFixed(1)} L',
          ),
        ],
      ),
    );
  }

  Widget _buildChartCard(Map<String, DailyRecord> byDate, int latestWaterGoal) {
    final isSteps = _metric == _ChartMetric.steps;
    final today = _todayUtc();
    final days = [
      for (var i = 6; i >= 0; i--) today.subtract(Duration(days: i)),
    ];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.bar_chart_rounded, 'Last 7 days'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              _metricChip('Steps', _ChartMetric.steps),
              _metricChip('Water', _ChartMetric.water),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in days)
                  Expanded(
                    child: _bar(
                      d,
                      byDate[dateKey(d)],
                      isSteps
                          ? widget.targetSteps
                          : (byDate[dateKey(d)]?.waterGoal ?? latestWaterGoal),
                      isSteps,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSteps
                ? 'Steps per day · solid bar = goal of ${_thousands(widget.targetSteps)} reached'
                : 'Litres per day · solid bar = daily water goal reached',
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _buildWeightCard(List<DailyRecord> records) {
    final first = records.last; // oldest
    final latest = records.first; // newest
    final diff = latest.weightKg - first.weightKg;
    final sign = diff > 0 ? '+' : '-';
    final changeText = diff.abs() < 0.05
        ? 'No change yet'
        : '$sign${diff.abs().toStringAsFixed(1)} kg';

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.monitor_weight_outlined, 'Weight journey'),
          const SizedBox(height: 14),
          Row(
            children: [
              _miniStat(
                'Starting (${_shortDate(first.date)})',
                '${first.weightKg.toStringAsFixed(1)} kg',
              ),
              _miniStat('Now', '${latest.weightKg.toStringAsFixed(1)} kg'),
              _miniStat('Change', changeText),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Update your weight in Profile (top right) whenever it changes — '
            'this page keeps track for you.',
            style: TextStyle(fontSize: 11, color: _mutedColor),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyList(List<DailyRecord> records) {
    final shown = records.take(30).toList();

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.history, 'Day by day'),
          const SizedBox(height: 12),
          for (final r in shown) _dayRow(r),
          if (records.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Showing the latest 30 of ${records.length} days.',
                style: TextStyle(fontSize: 11, color: _mutedColor),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(List<DailyRecord> records) {
    final byDate = {for (final r in records) r.date: r};
    final activeDays = records.where((r) => r.isActive).length;
    final streak = _currentStreak(byDate);
    final best = _bestStreak(records);
    final perfect = records.where((r) => r.isPerfect).length;

    final stepsNow = _weekAvg(byDate, 1, (r) => r.steps);
    final stepsPrev = _weekAvg(byDate, 8, (r) => r.steps);
    final waterNow = _weekAvg(byDate, 1, (r) => r.water);
    final waterPrev = _weekAvg(byDate, 8, (r) => r.water);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      physics: const BouncingScrollPhysics(),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInsightCard(activeDays, stepsNow, stepsPrev),
              const SizedBox(height: 16),
              Row(
                children: [
                  _statTile('🔥', '$streak', 'Current streak'),
                  const SizedBox(width: 10),
                  _statTile('🏆', '$best', 'Best streak'),
                  const SizedBox(width: 10),
                  _statTile('⭐', '$perfect', 'Perfect days'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Streak = days in a row with something logged. '
                'Perfect day = all 3 daily habits ticked.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: _mutedColor),
              ),
              const SizedBox(height: 16),
              _buildWeeklyCard(stepsNow, stepsPrev, waterNow, waterPrev),
              const SizedBox(height: 16),
              _buildChartCard(byDate, records.first.waterGoal),
              const SizedBox(height: 16),
              _buildWeightCard(records),
              const SizedBox(height: 16),
              _buildDailyList(records),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    final Widget body;

    if (records == null) {
      body = Center(child: CircularProgressIndicator(color: _p.primaryColor));
    } else if (!HistoryDb.instance.ready) {
      body = _message('History could not be opened on this device.');
    } else if (records.isEmpty) {
      body = _message(
        'No history yet. Add some water or steps on the dashboard, then come back!',
      );
    } else {
      body = _buildContent(records);
    }

    return Container(
      decoration: BoxDecoration(gradient: _p.bgGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: _titleColor,
          title: Text(
            'My Progress & History',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _titleColor,
            ),
          ),
        ),
        body: body,
      ),
    );
  }
}
