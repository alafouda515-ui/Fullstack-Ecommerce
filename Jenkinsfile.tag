// Pipeline 3 : Build versionne sur tag vX.Y.Z + archivage d'artefacts
// Parallelisation : build / run / smoke pour Node 18 et Node 20
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        IMAGE    = 'ecom-app'
        GIT_BASH = '"C:\\Program Files\\Git\\usr\\bin\\bash.exe"'
        PATH     = "C:\\Program Files\\Git\\ucrt64\\bin;${env.PATH}"
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                bat 'git log -1 --oneline'
            }
        }

        stage('Setup') {
            steps {
                script {
                    // Le tag doit respecter le format vX.Y.Z
                    if (!(env.TAG_NAME ==~ /^v\d+\.\d+\.\d+$/)) {
                        error("Tag invalide : '${env.TAG_NAME}' (format attendu : vX.Y.Z)")
                    }
                    echo "Version a construire : ${env.TAG_NAME}"
                }
                bat 'docker --version'
                bat 'git --version'
                bat 'if not exist reports mkdir reports'
                bat 'if not exist artifacts mkdir artifacts'
            }
        }

        stage('Build') {
            parallel {
                stage('Build Node 18') {
                    steps {
                        bat '''
                        docker build --build-arg NODE_VERSION=18 -t %IMAGE%:%TAG_NAME%-node18 . > reports\\build-node18.log 2>&1
                        set RC=%ERRORLEVEL%
                        type reports\\build-node18.log
                        exit /b %RC%
                        '''
                    }
                }
                stage('Build Node 20') {
                    steps {
                        bat '''
                        docker build --build-arg NODE_VERSION=20 -t %IMAGE%:%TAG_NAME%-node20 . > reports\\build-node20.log 2>&1
                        set RC=%ERRORLEVEL%
                        type reports\\build-node20.log
                        exit /b %RC%
                        '''
                    }
                }
            }
        }

        stage('Run (Docker)') {
            parallel {
                stage('Run Node 18') {
                    steps {
                        bat 'docker run -d --name ecom-tag-n18-%BUILD_NUMBER% -p 8084:80 %IMAGE%:%TAG_NAME%-node18'
                    }
                }
                stage('Run Node 20') {
                    steps {
                        bat 'docker run -d --name ecom-tag-n20-%BUILD_NUMBER% -p 8085:80 %IMAGE%:%TAG_NAME%-node20'
                    }
                }
            }
        }

        stage('Smoke Test') {
            parallel {
                stage('Smoke Node 18') {
                    steps {
                        bat 'set "PATH=C:\\Program Files\\Git\\usr\\bin;%PATH%" && %GIT_BASH% smoke_test.sh http://localhost:8084 reports/smoke_node18.txt'
                    }
                }
                stage('Smoke Node 20') {
                    steps {
                        bat 'set "PATH=C:\\Program Files\\Git\\usr\\bin;%PATH%" && %GIT_BASH% smoke_test.sh http://localhost:8085 reports/smoke_node20.txt'
                    }
                }
            }
        }

        stage('Archive Artifacts') {
            steps {
                bat 'docker logs ecom-tag-n18-%BUILD_NUMBER% > reports\\container-node18.log 2>&1'
                bat 'docker logs ecom-tag-n20-%BUILD_NUMBER% > reports\\container-node20.log 2>&1'
                bat 'docker image ls %IMAGE% > reports\\images.txt 2>&1'
                // Artefact versionne : le site compile (dist) en .zip
                bat 'docker cp ecom-tag-n20-%BUILD_NUMBER%:/usr/share/nginx/html artifacts\\dist'
                bat 'powershell -NoProfile -Command "Compress-Archive -Path artifacts\\dist\\* -DestinationPath artifacts\\ecom-app-%TAG_NAME%-dist.zip -Force"'
                writeFile file: 'reports/pipeline_report.txt', text: """Pipeline      : TAG (Build versionne)
Version       : ${env.TAG_NAME}
Build         : #${env.BUILD_NUMBER}
Commit        : ${env.GIT_COMMIT}
Build Node 18 : PASSED
Build Node 20 : PASSED
Smoke Node 18 : PASSED
Smoke Node 20 : PASSED
Artefact      : ecom-app-${env.TAG_NAME}-dist.zip
Statut global : SUCCESS
"""
                archiveArtifacts artifacts: 'reports/**, artifacts/*.zip', allowEmptyArchive: true, fingerprint: true
            }
        }

        stage('Cleanup') {
            steps {
                bat 'docker rm -f ecom-tag-n18-%BUILD_NUMBER% || exit /b 0'
                bat 'docker rm -f ecom-tag-n20-%BUILD_NUMBER% || exit /b 0'
            }
        }
    }

    post {
        failure {
            bat 'if not exist reports mkdir reports'
            bat 'docker logs ecom-tag-n18-%BUILD_NUMBER% > reports\\container-node18.log 2>&1 || exit /b 0'
            bat 'docker logs ecom-tag-n20-%BUILD_NUMBER% > reports\\container-node20.log 2>&1 || exit /b 0'
            writeFile file: 'reports/pipeline_report.txt', text: """Pipeline      : TAG (Build versionne)
Version       : ${env.TAG_NAME}
Build         : #${env.BUILD_NUMBER}
Commit        : ${env.GIT_COMMIT}
Statut global : FAILED (voir les logs build-*.log et smoke_*.txt)
"""
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            bat 'docker rm -f ecom-tag-n18-%BUILD_NUMBER% || exit /b 0'
            bat 'docker rm -f ecom-tag-n20-%BUILD_NUMBER% || exit /b 0'
        }
    }
}
