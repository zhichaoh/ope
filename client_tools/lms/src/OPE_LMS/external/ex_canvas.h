#ifndef EX_CANVAS_H
#define EX_CANVAS_H

#include <QObject>
#include <QString>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QJsonObject>
#include <QUrl>
#include <QDesktopServices>
#include <QStandardPaths>

#include "../db.h"
#include "cm/cm_httpserver.h"
#include "cm/cm_webrequest.h"
#include "cm/cm_users.h"

class EX_Canvas : public QObject
{
    Q_OBJECT
public:
    // Must provide db and settings objects during object creation
    explicit EX_Canvas(QObject *parent = 0, APP_DB *db = NULL, QSettings *app_settings = NULL);

public slots:

    // ==================================================
    // pull data from canvas - used during sync

    // Get the info for the current student
    bool pullStudentInfo();
    // Get the list of courses for the current student
    bool pullCourses();
    // Get the list of modules for all courses
    bool pullModules();
    // Get the list of pages for each module in all courses
    bool pullModuleItems();
    // Get list of files to pull
    bool pullCourseFilesInfo();
    // Pull a file binary
    bool pullCourseFilesBinaries();
    // Pull list of pages for courses
    bool pullCoursePages();
    // Pul list of messages
    bool pullMessages(QString scope="inbox");

    // =================================================
    // push data to canvas - used during sync
    // Push assignments
    bool pushAssignments();
    // Push messages
    bool pushMessages();
    // Push any files for this student (e.g. attachments)
    bool pushFiles();
    
    


    // OLD - used if you use the full OAUTH cycle to login and get a auth token
    bool LinkToCanvas(QString redirect_url, QString client_id);
    void FinalizeLinkToCanvas(CM_HTTPRequest *request, CM_HTTPResponse *response);


    // =================================================
    // Core network calls - used to call canvas APIs
    // Build the API url and insert auth tokens
    QJsonDocument CanvasAPICall(QString api_call, QString method = "GET", QHash<QString, QString> *p = NULL);
    // Low level network call - make the actual connection to canvas, auto pull additional pages - BLOCKING
    QString NetworkCall(QString url, QString method = "GET", QHash<QString, QString> *p = NULL, QHash<QString, QString> *headers = NULL);
    // Download a file to a local path
    bool DownloadFile(QString url, QString local_path);

    // Store the auth token so that requests can be sent to canvas on behalf of this user
    void SetCanvasAccessToken(QString token);

private:
    // ?? Still needed?? Only if using full OAUTH cycle
    QString canvas_client_id;
    QString canvas_client_secret;

    // Access token for the current user/student
    QString canvas_access_token;
    // Base URL of canvas server - e.g.: https://canvas.ed
    QString canvas_server;

    // Web request used by NetworkCall - hands off
    CM_WebRequest *web_request;

    // Database pointer - provided by app - where do we store our canvas info?
    APP_DB *_app_db;

    // App settings object - provided by app
    QSettings *_app_settings;

private slots:


    //// TODO
    ///
    /// File/Folder API
    /// Course API
    /// User API
    /// Accounts API
    /// Roles API
    /// Enrollments API
    /// Calendar API
    /// Assignment API
    /// Conversations API
    /// Discussions API
    /// Gradebook API
    /// Group API
    /// Module API
    /// Quizzes API
    /// Sections API
    /// Submissions API
    /// Tabs API ????
    /// WikiPages API

signals:

public slots:

};

#endif // EX_CANVAS_H
