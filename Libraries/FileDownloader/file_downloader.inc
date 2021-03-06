#if defined _file_downloader_included
 #endinput
#endif
#define _file_downloader_included


public SharedPlugin:__pl_file_downloader = 
{
	name = "file_downloader",
	file = "API_FileDownloader.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};


functag public Callback_OnDownloadSuccess(const String:file_save_path[]);
functag public Callback_OnDownloadFailed(const String:file_save_path[]);


native FileDownloader_DownloadFile(const String:file_url[], const String:file_save_path[], Callback_OnDownloadSuccess:success_callback=INVALID_FUNCTION, Callback_OnDownloadFailed:failed_callback=INVALID_FUNCTION);


#if !defined REQUIRE_PLUGIN
public __pl_file_downloader_SetNTVOptional()
{
	MarkNativeAsOptional("FileDownloader_DownloadFile");
}
#endif