  private getDates(
    asset: { id: string; originalPath: string; fileCreatedAt: Date },
    exifTags: ImmichTags,
    stats: Stats,
  ) {
    const result = firstDateTime(exifTags);
    const tag = result?.tag;
    const dateTime = result?.dateTime;

    let dateTimeOriginal: DateTime;

    if (dateTime) {
      dateTimeOriginal = dateTime.toDateTime();

      this.logger.verbose(
        `ExifTag ${tag}='${dateTime}' (rawValue='${dateTime.rawValue}'), dateTimeOriginal='${dateTimeOriginal.toISO()}' for asset ${asset.id}: ${asset.originalPath}`,
      );

      if (exifTags.zone == null && !dateTime.rawValue?.endsWith('Z')) {
        this.logger.debug(
          `No timezone information found, using configured TZ='${process.env.TZ}' for asset ${asset.id}: ${asset.originalPath}`,
        );
      }
    } else {
      // FileCreateDate is unavailable on Linux. Use the earliest available
      // file timestamp, interpreted in the server's configured TZ.
      dateTimeOriginal = DateTime.fromMillis(
        Math.min(
          asset.fileCreatedAt.getTime(),
          stats.birthtimeMs ? Math.min(stats.mtimeMs, stats.birthtimeMs) : stats.mtime.getTime(),
        ),
      );

      this.logger.verbose(
        `Earliest dateTimeOriginal='${dateTimeOriginal.toISO()}' for asset ${asset.id}: ${asset.originalPath}`,
      );
    }

    const timeZone = `UTC${dateTimeOriginal.toFormat('ZZ')}`;

    // Store the local wall-clock value separately, while fileCreatedAt
    // remains the same absolute instant for ordering.
    const localDateTime = dateTimeOriginal.setZone('UTC', { keepLocalTime: true });

    this.logger.debug(
      `Found localDateTime='${localDateTime.toISO()}' and timeZone='${timeZone}' for asset ${asset.id}: ${asset.originalPath}`,
    );

    return {
      timeZone,
      localDateTime: localDateTime.toJSDate(),
      dateTimeOriginal: dateTimeOriginal.toJSDate(),
    };
  }

