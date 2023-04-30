FROM node
RUN mkdir workspace
WORKDIR workspace
COPY package.* ./
RUN  npm i
COPY . .
CMD ["node","server.js"]